import AppKit
import SwiftUI
import Combine
import AuxCore

@MainActor
final class AppModel: ObservableObject {
    let settings: SettingsStore
    let isPreview: Bool
    @Published var snapshot = PlaybackSnapshot(state: .notRunning)
    @Published var publication = PublicationStatus()
    @Published var artwork: NSImage?
    @Published var showingSettings = false
    @Published var musicConnected = false
    @Published var musicError: String?
    @Published var permissionDenied = false
    @Published var artworkStatus = ""
    @Published var artworkReadError: String?
    @Published var extras: TrackExtras?
    @Published var panelVisible = false
    @Published var sleeping = false

    private let music = MusicBridge()
    private let publisher = DiscordPublisher()
    private let artworkResolver: ArtworkResolver
    private let uploads: HostedArtwork
    private var resolvedArtwork = ResolvedArtworkCache()
    private var artworkRecovery: Task<Void, Never>?
    private var repairingArtworkURL: URL?
    private var timeline = PlaybackTimeline()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var enrichment: Task<Void, Never>?
    private var localArtwork: Data?
    private var fallbackArtworkURL: URL?
    private var imageIdentity = ""
    private var enrichmentKey = ""
    private var imageRetryAt = Date.distantPast
    private var revision: UInt64 = 0
    private var lifecycle: UInt64 = 0
    private var stopped = false
    private var refreshing = false
    private var refreshAgain = false
    private var forceTimeline = false
    private var nextObservation = Date.distantPast
    private var settingsSubscription: AnyCancellable?

    init(preview: Bool = false) {
        isPreview = preview
        settings = SettingsStore(preview: preview)
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Aux", isDirectory: true)
        uploads = HostedArtwork(directory: directory)
        artworkResolver = ArtworkResolver(catalog: CatalogResolver(directory: directory), uploads: uploads, images: ArtworkService())
        settings.onChange = { [weak self] in self?.settingsChanged() }
        settingsSubscription = settings.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        if preview { loadPreview() }
    }

    var musicAccessTitle: String {
        if permissionDenied { return "Access denied" }
        if musicConnected { return "Connected" }
        if !settings.musicAccessRequested { return "Not connected" }
        if musicError != nil { return "Needs attention" }
        if snapshot.state == .notRunning { return "Apple Music is closed" }
        return "Connecting…"
    }

    var statusTitle: String {
        if isPreview { return "Design preview" }
        if !settings.musicAccessRequested { return "Connect Apple Music" }
        if permissionDenied { return "Music access needed" }
        if musicError != nil { return "Waiting for Music" }
        if !settings.sharingEnabled { return publication.accepted == nil ? "Sharing is off" : "Turning sharing off…" }
        if sleeping { return "Mac is sleeping" }
        if publication.connection == .paused { return "Paused · Discord disconnected" }
        if publication.connection != .connected { return "Waiting for Discord" }
        if publication.pending { return "Updating Discord…" }
        if publication.accepted != nil { return snapshot.state == .paused ? "Disconnecting from Discord…" : "Sharing on Discord" }
        switch snapshot.state {
        case .notRunning: return "Apple Music is closed"
        case .stopped: return "Ready when you play"
        case .paused: return "Paused · Discord disconnected"
        case .playing: return "Connected to Discord"
        }
    }
    var statusColor: Color {
        if isPreview { return .accentColor }
        if !settings.sharingEnabled { return .secondary }
        if publication.connection == .connected, publication.accepted != nil, !publication.pending { return .green }
        if !settings.musicAccessRequested || permissionDenied || musicError != nil { return .orange }
        return .secondary
    }
    var isSharing: Bool { !isPreview && publication.connection == .connected && publication.accepted != nil }

    var artworkDiagnostic: String {
        guard publication.connection == .connected, publication.accepted != nil else { return artworkStatus }
        let source = publication.artworkMessage ?? artworkStatus
        switch publication.artwork {
        case .none: return source
        case .checking: return source + " · checking Discord image"
        case .available: return source + " · Discord image verified"
        case .unavailable: return publication.artworkMessage ?? "Artwork unavailable in Discord · will retry"
        }
    }

    func start() {
        guard !isPreview, !stopped, timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.willSleep() }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.didWake() }
        })
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      ["com.apple.Music", "com.hnc.Discord", "com.hnc.DiscordPTB", "com.hnc.DiscordCanary"].contains(app.bundleIdentifier ?? "") else { return }
                Task { @MainActor in self?.requestRefresh() }
            })
        }
        // Helpful when delivered, never our only source of truth.
        observers.append(DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.Music.playerInfo"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.requestRefresh() }
        })
        requestRefresh()
    }

    func requestRefresh() {
        guard !stopped, !sleeping else { return }
        nextObservation = .distantPast
        if refreshing { refreshAgain = true; return }
        Task { await refresh() }
    }

    func refresh() async {
        guard !isPreview, !stopped, !sleeping, !refreshing else { return }
        let ownLifecycle = lifecycle
        refreshing = true
        defer {
            refreshing = false
            if refreshAgain { refreshAgain = false; requestRefresh() }
        }
        if settings.musicAccessRequested, Date() >= nextObservation {
            do {
                let observed = try await music.snapshot()
                guard !stopped, !sleeping, ownLifecycle == lifecycle else { return }
                snapshot = timeline.accept(observed, force: forceTimeline)
                forceTimeline = false
                musicError = nil; permissionDenied = false
                musicConnected = observed.state != .notRunning
                nextObservation = Date().addingTimeInterval(snapshot.state == .playing || snapshot.state == .stopped ? 1 : 4)
            } catch MusicError.trackChanged {
                guard !stopped, !sleeping, ownLifecycle == lifecycle else { return }
                musicConnected = true
                musicError = nil; permissionDenied = false
                // Keep the accepted song until Music supplies a consistent
                // replacement. A track-change race is not a stop command.
                nextObservation = .distantPast
                return
            } catch {
                guard !stopped, !sleeping, ownLifecycle == lifecycle else { return }
                musicConnected = false
                musicError = error.localizedDescription
                if case MusicError.permissionDenied = error { permissionDenied = true }
                snapshot = timeline.accept(.init(state: .stopped))
                nextObservation = Date().addingTimeInterval(10)
            }
        }
        guard !stopped, !sleeping, ownLifecycle == lifecycle else { return }
        refreshArtworkIfNeeded()
        await publish()
    }

    private func publish() async {
        guard !isPreview, !stopped, !sleeping else { return }
        revision &+= 1
        let ownRevision = revision
        let desired = sleeping || musicError != nil ? nil : PresencePayload.make(snapshot: snapshot, extras: extras, options: settings.options)
        let paused = snapshot.state == .paused && settings.sharingEnabled && musicError == nil
        let result = await publisher.reconcile(desired, applicationID: SettingsStore.applicationID, revision: ownRevision, paused: paused, enabled: settings.sharingEnabled, fallbackArtworkURL: fallbackArtworkURL)
        guard !stopped, !sleeping, ownRevision == revision else { return }
        publication = result
        if settings.shareLocalArtwork, settings.sharingEnabled, snapshot.state == .playing,
           let failedURL = result.failedArtworkURL, failedURL.host == HostedArtwork.baseURL.host,
           artworkRecovery == nil {
            artworkRecovery = Task { [weak self] in
                guard let self else { return }
                let missing = await self.uploads.invalidateIfMissing(failedURL)
                self.artworkRecovery = nil
                guard !Task.isCancelled, missing else { return }
                self.resolvedArtwork.remove(artworkURL: failedURL)
                guard self.extras?.artworkURL == failedURL else { return }
                self.repairingArtworkURL = failedURL
                self.imageRetryAt = .distantPast
                self.refreshArtworkIfNeeded()
            }
        }
    }

    private func settingsChanged() {
        guard !isPreview, !stopped else { return }
        if !settings.shareLocalArtwork, extras?.artworkURL?.host == HostedArtwork.baseURL.host {
            extras?.artworkURL = nil
        }
        refreshArtworkIfNeeded()
        Task { await publish() }
        requestRefresh()
    }

    private func refreshArtworkIfNeeded() {
        guard !stopped, !sleeping else { return }
        guard let track = snapshot.track else {
            enrichment?.cancel(); enrichment = nil
            imageIdentity = ""; enrichmentKey = ""; artwork = nil; extras = nil; localArtwork = nil; artworkStatus = ""; artworkReadError = nil
            fallbackArtworkURL = nil
            return
        }
        let uploadAllowed = settings.shareLocalArtwork && settings.sharingEnabled && snapshot.state == .playing
        let key = track.identity + "|" + settings.country + "|\(uploadAllowed)|\(settings.shareLocalArtwork)"
        let newTrack = imageIdentity != track.identity
        guard key != enrichmentKey || (enrichment == nil && Date() >= imageRetryAt) else { return }
        enrichment?.cancel()
        enrichmentKey = key
        imageIdentity = track.identity
        imageRetryAt = .distantFuture
        if newTrack { artwork = nil; localArtwork = nil; extras = nil; fallbackArtworkURL = nil; artworkReadError = nil }
        if let cached = resolvedArtwork.entry(for: key) {
            let resolved = cached.resolution
            extras = resolved.extras
            fallbackArtworkURL = resolved.fallbackArtworkURL
            localArtwork = cached.localArtwork
            imageRetryAt = resolved.retryAt
            if let image = resolved.image { setArtwork(image) }
            artworkStatus = resolved.source == .library ? "Library artwork hosted by Aux" : "Apple catalog artwork"
            if cached.complete {
                enrichment = nil
                return
            }
        }
        let country = settings.country
        artworkStatus = "Finding artwork…"
        enrichment = Task { [weak self] in
            guard let self else { return }
            if self.localArtwork == nil {
                let raw: Data?
                do {
                    raw = try await self.music.artwork(for: track)
                    guard !Task.isCancelled, self.enrichmentKey == key else { return }
                    self.artworkReadError = nil
                } catch {
                    raw = nil
                    guard !Task.isCancelled, self.enrichmentKey == key else { return }
                    self.artworkReadError = error.localizedDescription
                }
                guard !Task.isCancelled, self.enrichmentKey == key else { return }
                if let raw, let thumbnail = ArtworkService.thumbnail(raw) {
                    self.localArtwork = thumbnail
                    self.setArtwork(thumbnail)
                }
            }
            if uploadAllowed, self.localArtwork != nil { self.artworkStatus = "Sharing library artwork…" }
            let resolved: ArtworkResolution
            do {
                resolved = try await self.artworkResolver.resolve(track: track, country: country, localArtwork: self.localArtwork, uploadAllowed: uploadAllowed) { [weak self] url in
                    guard !Task.isCancelled else { return }
                    await self?.publishLibraryArtwork(url, key: key)
                }
            } catch { return } // Cancellation: a newer track or settings change owns enrichment.
            guard !Task.isCancelled, self.enrichmentKey == key else { return }
            self.imageRetryAt = resolved.retryAt
            if self.artwork == nil, let image = resolved.image { self.setArtwork(image) }
            switch resolved.source {
            case .library: self.artworkStatus = "Library artwork hosted by Aux"
            case .catalog:
                self.artworkStatus = resolved.uploadFailed ? "Apple catalog artwork · local upload will retry" : "Apple catalog artwork"
            case .none:
                if resolved.uploadFailed { self.artworkStatus = "Local artwork upload unavailable · will retry" }
                else if self.localArtwork != nil { self.artworkStatus = "No Apple cover · local artwork stays in Aux" }
                else { self.artworkStatus = self.artworkReadError == nil ? "No artwork available" : "Music artwork could not be read · will retry" }
            }
            if let error = resolved.uploadError { self.artworkStatus += " · " + error }
            self.extras = resolved.extras
            self.fallbackArtworkURL = resolved.fallbackArtworkURL
            self.resolvedArtwork.store(resolved, localArtwork: self.localArtwork, for: key)
            self.enrichment = nil
            await self.publish()
        }
    }

    private func publishLibraryArtwork(_ url: URL, key: String) async {
        guard !Task.isCancelled, enrichmentKey == key, settings.shareLocalArtwork,
              settings.sharingEnabled, snapshot.state == .playing else { return }
        var updated = extras ?? TrackExtras()
        updated.artworkURL = url
        extras = updated
        artworkStatus = "Library artwork hosted by Aux"
        // Cache the early library result even if a track switch cancels the
        // slower catalog lookup before it completes.
        resolvedArtwork.store(.init(extras: updated, image: localArtwork, source: .library,
                                    retryAt: .distantFuture, uploadFailed: false,
                                    fallbackArtworkURL: fallbackArtworkURL), localArtwork: localArtwork, for: key, complete: false)
        if repairingArtworkURL == url {
            repairingArtworkURL = nil
            await publisher.retryArtwork(url)
        }
        await publish()
    }

    private func setArtwork(_ data: Data) {
        artwork = NSImage(data: data)
    }

    func connectMusic() { settings.musicAccessRequested = true; permissionDenied = false; requestRefresh() }
    func openMusic() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music") { NSWorkspace.shared.openApplication(at: url, configuration: .init()) }
    }
    func openAutomationSettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!) }
    func retryDiscord() {
        guard !isPreview, !stopped, !sleeping else { return }
        Task { await publisher.retry(); await publish() }
    }
    func willSleep() {
        guard !isPreview, !stopped else { return }
        lifecycle &+= 1
        revision &+= 1
        let ownRevision = revision
        sleeping = true
        enrichment?.cancel(); enrichment = nil; enrichmentKey = ""
        Task {
            await publisher.disconnect(revision: ownRevision)
            guard ownRevision == revision, sleeping else { return }
            publication = .init()
        }
    }
    func didWake() {
        guard !isPreview, !stopped else { return }
        lifecycle &+= 1
        revision &+= 1
        sleeping = false
        forceTimeline = true
        // Refresh Music before publishing so sleep cannot preserve a stale track.
        Task { await publisher.retry(); requestRefresh() }
    }
    func shutdown() async {
        guard !stopped else { return }
        stopped = true
        lifecycle &+= 1
        revision &+= 1
        timer?.invalidate(); timer = nil
        enrichment?.cancel(); enrichment = nil
        artworkRecovery?.cancel(); artworkRecovery = nil
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        observers.removeAll()
        await publisher.disconnect(revision: revision)
    }

    func loadPreview(state: String = "playing") {
        let track = Track(id: "preview", title: "Daylight", artist: "Aster", album: "Soft Focus", duration: 248)
        snapshot = .init(state: state == "paused" ? .paused : .playing, track: track, position: 83)
        if state == "empty" { snapshot = .init(state: .stopped) }
        settings.musicAccessRequested = true
        musicConnected = true
        settings.sharingEnabled = true
        publication.connection = state == "paused" ? .paused : (state == "disconnected" ? .waiting : .connected)
        publication.accepted = PresencePayload.make(snapshot: snapshot, extras: nil, options: .init())
        artworkStatus = "Preview artwork"
    }
}
