import AppKit
import SwiftUI
import Combine
import ImageIO
import AuxCore

@MainActor
final class AppModel: ObservableObject {
    let settings: SettingsStore
    let isPreview: Bool
    @Published var snapshot = PlaybackSnapshot(state: .notRunning)
    @Published var publication = PublicationStatus()
    @Published var artwork: NSImage?
    @Published var accent = Color(red: 0.97, green: 0.43, blue: 0.28)
    @Published var musicError: String?
    @Published var permissionDenied = false
    @Published var artworkStatus = ""
    @Published var extras: TrackExtras?
    @Published var controlBusy = false
    @Published var panelVisible = false
    @Published var sleeping = false

    private let music = MusicBridge()
    private let publisher = DiscordPublisher()
    private let catalog: CatalogResolver
    private let images = ArtworkService()
    private var timeline = PlaybackTimeline()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var enrichment: Task<Void, Never>?
    private var localArtwork: Data?
    private var imageIdentity = ""
    private var enrichmentKey = ""
    private var imageRetryAt = Date.distantPast
    private var uploadedRefreshAt = Date.distantFuture
    private var revision: UInt64 = 0
    private var lifecycle: UInt64 = 0
    private var stopped = false
    private var refreshing = false
    private var refreshAgain = false
    private var forceTimeline = false
    private var nextObservation = Date.distantPast
    private var settingsSubscription: AnyCancellable?
    var onAppearanceChange: (() -> Void)?

    init(preview: Bool = false) {
        isPreview = preview
        settings = SettingsStore(preview: preview)
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Aux", isDirectory: true)
        catalog = CatalogResolver(directory: directory)
        settings.onChange = { [weak self] in self?.settingsChanged() }
        settingsSubscription = settings.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        if preview { loadPreview() }
    }

    var statusTitle: String {
        if isPreview { return "Design preview" }
        if !settings.musicAccessRequested { return "Connect Apple Music" }
        if permissionDenied { return "Music access needed" }
        if musicError != nil { return "Waiting for Music" }
        if !settings.sharingEnabled { return publication.accepted == nil ? "Sharing is off" : "Turning sharing off…" }
        if !settings.hasApplicationID { return "Set up Discord" }
        if sleeping { return "Mac is sleeping" }
        if publication.connection != .connected { return "Waiting for Discord" }
        if publication.pending { return "Updating Discord…" }
        if publication.accepted != nil { return snapshot.state == .paused ? "Sharing paused track" : "Sharing on Discord" }
        switch snapshot.state {
        case .notRunning: return "Apple Music is closed"
        case .stopped: return "Ready when you play"
        case .paused: return "Paused · presence hidden"
        case .playing: return "Connected to Discord"
        }
    }
    var statusColor: Color {
        if isPreview { return accent }
        if !settings.sharingEnabled { return .secondary }
        if publication.connection == .connected, publication.accepted != nil, !publication.pending { return .green }
        if !settings.musicAccessRequested || permissionDenied || !settings.hasApplicationID || musicError != nil { return .orange }
        return .secondary
    }
    var isSharing: Bool { !isPreview && publication.connection == .connected && publication.accepted != nil }
    var canControl: Bool { settings.musicAccessRequested && snapshot.state != .notRunning && !permissionDenied && !isPreview && !sleeping && !stopped }

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
                nextObservation = Date().addingTimeInterval(snapshot.state == .playing ? 1 : 4)
            } catch MusicError.trackChanged {
                guard !stopped, !sleeping, ownLifecycle == lifecycle else { return }
                // Clear potentially stale data until the next consistent observation.
                snapshot = timeline.accept(.init(state: .stopped))
                nextObservation = .distantPast
            } catch {
                guard !stopped, !sleeping, ownLifecycle == lifecycle else { return }
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
        let desired = sleeping || musicError != nil ? nil : PresencePayload.make(snapshot: snapshot, pausedAt: timeline.pausedAt, extras: extras, options: settings.options)
        let result = await publisher.reconcile(desired, applicationID: settings.applicationID, revision: ownRevision)
        guard !stopped, !sleeping, ownRevision == revision else { return }
        publication = result
    }

    private func settingsChanged() {
        guard !isPreview, !stopped else { return }
        onAppearanceChange?()
        refreshArtworkIfNeeded()
        Task { await publish() }
        requestRefresh()
    }

    private func refreshArtworkIfNeeded() {
        guard !stopped, !sleeping else { return }
        guard let track = snapshot.track else {
            enrichment?.cancel(); enrichment = nil
            imageIdentity = ""; enrichmentKey = ""; artwork = nil; extras = nil; localArtwork = nil; artworkStatus = ""
            accent = Color(red: 0.97, green: 0.43, blue: 0.28)
            return
        }
        let canUpload = settings.uploadArtwork && settings.sharingEnabled && settings.hasApplicationID &&
            PresencePayload.make(snapshot: snapshot, pausedAt: timeline.pausedAt, extras: nil, options: settings.options) != nil
        let key = track.identity + "|" + settings.country + "|\(canUpload)"
        let newTrack = imageIdentity != track.identity
        guard key != enrichmentKey || (enrichment == nil && Date() >= imageRetryAt) || Date() >= uploadedRefreshAt else { return }
        enrichment?.cancel()
        enrichmentKey = key
        imageIdentity = track.identity
        imageRetryAt = .distantFuture
        uploadedRefreshAt = .distantFuture
        if newTrack { artwork = nil; localArtwork = nil; extras = nil; accent = Color(red: 0.97, green: 0.43, blue: 0.28) }
        // Drop an uploaded URL immediately when uploading is disabled.
        if !canUpload, extras?.artworkURL?.host == "litter.catbox.moe" { extras?.artworkURL = nil }
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
            do {
                var resolved = try await self.catalog.resolve(track, country: country) ?? TrackExtras()
                guard !Task.isCancelled, self.enrichmentKey == key else { return }
                if let url = resolved.artworkURL {
                    self.artworkStatus = "Apple catalog artwork"
                    if self.artwork == nil, let image = try? await self.images.download(url) {
                        guard !Task.isCancelled, self.enrichmentKey == key else { return }
                        self.setArtwork(image)
                    }
                } else if canUpload, let data = self.localArtwork {
                    self.artworkStatus = "Uploading cover…"
                    resolved.artworkURL = try await self.images.upload(data)
                    self.uploadedRefreshAt = Date().addingTimeInterval(50 * 60)
                    self.artworkStatus = "Temporary cover · Catbox"
                } else {
                    self.artworkStatus = self.artwork == nil ? "No matching artwork" : "Local cover · visible in Aux"
                }
                guard !Task.isCancelled, self.enrichmentKey == key else { return }
                self.extras = resolved
                self.enrichment = nil
                await self.publish()
            } catch {
                guard !Task.isCancelled, self.enrichmentKey == key else { return }
                self.artworkStatus = "Artwork lookup unavailable"
                self.imageRetryAt = Date().addingTimeInterval(45)
                self.enrichment = nil
            }
        }
    }

    private func setArtwork(_ data: Data) {
        artwork = NSImage(data: data)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        var pixel = [UInt8](repeating: 0, count: 4)
        if let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            let color = NSColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
            if let hsb = color.usingColorSpace(.deviceRGB) {
                accent = Color(nsColor: NSColor(hue: hsb.hueComponent, saturation: max(0.3, min(0.7, hsb.saturationComponent)), brightness: max(0.7, hsb.brightnessComponent), alpha: 1))
            }
        }
    }

    func connectMusic() { settings.musicAccessRequested = true; permissionDenied = false; requestRefresh() }
    func control(_ command: MusicBridge.Command) {
        guard canControl, !controlBusy else { return }
        controlBusy = true
        Task {
            do { try await music.perform(command); forceTimeline = true; musicError = nil }
            catch { musicError = error.localizedDescription }
            controlBusy = false
            requestRefresh()
        }
    }
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
        settings.sharingEnabled = true
        publication.connection = state == "disconnected" ? .waiting : .connected
        publication.accepted = PresencePayload.make(snapshot: snapshot, pausedAt: Date(), extras: nil, options: .init(pauseBehavior: .fiveMinutes))
        artworkStatus = "Preview artwork"
    }
}
