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
    @Published var extras: TrackExtras?
    @Published var panelVisible = false
    @Published var sleeping = false

    private let music = MusicBridge()
    private let publisher = DiscordPublisher()
    private let catalog: CatalogResolver
    private let uploadedArtwork: CatboxArtwork
    private let images = ArtworkService()
    private var timeline = PlaybackTimeline()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var enrichment: Task<Void, Never>?
    private var localArtwork: Data?
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
        catalog = CatalogResolver(directory: directory)
        uploadedArtwork = CatboxArtwork(directory: directory)
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
                nextObservation = Date().addingTimeInterval(snapshot.state == .playing ? 1 : 4)
            } catch MusicError.trackChanged {
                guard !stopped, !sleeping, ownLifecycle == lifecycle else { return }
                musicConnected = true
                musicError = nil; permissionDenied = false
                // Clear potentially stale data until the next consistent observation.
                snapshot = timeline.accept(.init(state: .stopped))
                nextObservation = .distantPast
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
        let result = await publisher.reconcile(desired, applicationID: SettingsStore.applicationID, revision: ownRevision, paused: paused)
        guard !stopped, !sleeping, ownRevision == revision else { return }
        publication = result
    }

    private func settingsChanged() {
        guard !isPreview, !stopped else { return }
        if !settings.shareLocalArtwork, extras?.artworkURL?.host == "files.catbox.moe" {
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
            imageIdentity = ""; enrichmentKey = ""; artwork = nil; extras = nil; localArtwork = nil; artworkStatus = ""
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
        if newTrack { artwork = nil; localArtwork = nil; extras = nil }
        let country = settings.country
        artworkStatus = "Finding artwork…"
        enrichment = Task { [weak self] in
            guard let self else { return }
            if self.localArtwork == nil {
                let raw = try? await self.music.artwork(for: track)
                guard !Task.isCancelled, self.enrichmentKey == key else { return }
                if let raw, let thumbnail = ArtworkService.thumbnail(raw) {
                    self.localArtwork = thumbnail
                    self.setArtwork(thumbnail)
                }
            }
            var resolved = TrackExtras()
            var catalogUnavailable = false
            do { resolved = try await self.catalog.resolve(track, country: country) ?? TrackExtras() }
            catch { catalogUnavailable = true }
            guard !Task.isCancelled, self.enrichmentKey == key else { return }
            if let url = resolved.artworkURL {
                // A returned URL can still be broken. Check it even when the
                // panel already has a local cover, then fall back if needed.
                let image = try? await self.images.download(url)
                guard !Task.isCancelled, self.enrichmentKey == key else { return }
                if let image {
                    self.artworkStatus = "Apple catalog artwork"
                    if self.artwork == nil { self.setArtwork(image) }
                } else {
                    resolved.artworkURL = nil
                    catalogUnavailable = true
                }
            }
            if resolved.artworkURL == nil {
                self.imageRetryAt = Date().addingTimeInterval(catalogUnavailable || self.localArtwork == nil ? 45 : 3600)
                if uploadAllowed, let local = self.localArtwork {
                    self.artworkStatus = "Uploading cover to Catbox…"
                    do {
                        let url = try await self.uploadedArtwork.resolve(local)
                        guard !Task.isCancelled, self.enrichmentKey == key else { return }
                        resolved.artworkURL = url
                        self.artworkStatus = "Local artwork shared via Catbox"
                    } catch {
                        guard !Task.isCancelled, self.enrichmentKey == key else { return }
                        if case CatboxError.retryAfter(let date) = error {
                            self.imageRetryAt = date
                        } else if error is CancellationError || (error as? URLError)?.code == .cancelled {
                            // A previous song may have canceled a shared upload
                            // for this same cover just as the new song joined it.
                            self.imageRetryAt = Date().addingTimeInterval(5)
                        } else { self.imageRetryAt = Date().addingTimeInterval(15 * 60) }
                        self.artworkStatus = "Catbox upload unavailable · will retry"
                    }
                } else if self.localArtwork != nil {
                    self.artworkStatus = "No Apple cover · local artwork stays in Aux"
                } else { self.artworkStatus = "No artwork available" }
            }
            guard !Task.isCancelled, self.enrichmentKey == key else { return }
            self.extras = resolved
            self.enrichment = nil
            await self.publish()
        }
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
            await publisher.disconnect(clear: true, revision: ownRevision)
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
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        observers.removeAll()
        await publisher.disconnect(clear: true, revision: revision)
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
