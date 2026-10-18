import Foundation

public struct ArtworkResolution: Sendable {
    public enum Source: Sendable { case library, catalog, none }
    public var extras: TrackExtras
    public var image: Data?
    public var source: Source
    public var retryAt: Date
    public var uploadFailed: Bool
    public var fallbackArtworkURL: URL? = nil
    public var uploadError: String? = nil

    public init(extras: TrackExtras, image: Data?, source: Source, retryAt: Date, uploadFailed: Bool,
                fallbackArtworkURL: URL? = nil, uploadError: String? = nil) {
        self.extras = extras; self.image = image; self.source = source
        self.retryAt = retryAt; self.uploadFailed = uploadFailed
        self.fallbackArtworkURL = fallbackArtworkURL; self.uploadError = uploadError
    }
}

/// Keeps repeat tracks ready before the first Discord publication. The caller's
/// key includes track identity and sharing/catalog settings to prevent leaks.
public struct ResolvedArtworkCache {
    public struct Entry {
        public var resolution: ArtworkResolution
        public var localArtwork: Data?
        public var complete: Bool
    }
    private var entries: [String: Entry] = [:]
    private var recency: [String] = []
    private let capacity: Int

    public init(capacity: Int = 64) { self.capacity = max(1, capacity) }

    public mutating func entry(for key: String, at now: Date = Date()) -> Entry? {
        guard var entry = entries[key] else { return nil }
        // Retrying a failed upload or catalog lookup should not blank an
        // already usable cover while enrichment runs in the background.
        if entry.resolution.retryAt <= now { entry.complete = false }
        touch(key)
        return entry
    }

    public mutating func store(_ resolution: ArtworkResolution, localArtwork: Data?, for key: String, complete: Bool = true) {
        guard resolution.extras.artworkURL != nil, resolution.source != .none else { return }
        entries[key] = Entry(resolution: resolution, localArtwork: localArtwork, complete: complete)
        touch(key)
        while recency.count > capacity { entries[recency.removeFirst()] = nil }
    }

    public mutating func remove(artworkURL: URL) {
        entries = entries.filter { $0.value.resolution.extras.artworkURL != artworkURL }
        recency.removeAll { entries[$0] == nil }
    }

    private mutating func touch(_ key: String) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }
}

/// Prefer the library's actual cover; catalog matching still supplies song links.
public struct ArtworkResolver: Sendable {
    private let lookup: @Sendable (Track, String) async throws -> TrackExtras?
    private let upload: @Sendable (Data) async throws -> URL
    private let download: @Sendable (URL) async throws -> Data?

    public init(catalog: CatalogResolver, uploads: HostedArtwork, images: ArtworkService) {
        self.init(
            lookup: { try await catalog.resolve($0, country: $1) },
            upload: { try await uploads.resolve($0) },
            download: { try await images.download($0) }
        )
    }

    init(
        lookup: @escaping @Sendable (Track, String) async throws -> TrackExtras?,
        upload: @escaping @Sendable (Data) async throws -> URL,
        download: @escaping @Sendable (URL) async throws -> Data?
    ) {
        self.lookup = lookup; self.upload = upload; self.download = download
    }

    public func resolve(track: Track, country: String, localArtwork: Data?, uploadAllowed: Bool,
                        onLibraryArtwork: @Sendable (URL) async -> Void = { _ in }) async throws -> ArtworkResolution {
        try Task.checkCancellation()
        // Resolve links alongside the upload, without letting a catalog cover
        // override the library image or making a catalog outage block it.
        async let catalog = lookup(track, country)
        var localURL: URL?
        var retryAt = Date.distantFuture
        var uploadFailed = false
        var uploadError: String?
        if uploadAllowed, let localArtwork {
            do {
                localURL = try await upload(localArtwork)
                try Task.checkCancellation()
                if let localURL { await onLibraryArtwork(localURL) }
            }
            catch {
                try Task.checkCancellation()
                uploadFailed = true
                uploadError = error.localizedDescription
                if case ArtworkUploadError.retryAfter(let date) = error {
                    retryAt = date
                } else if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    // Another caller can cancel a shared upload. The current
                    // track should retry soon, while using the catalog cover.
                    retryAt = Date().addingTimeInterval(5)
                } else { retryAt = Date().addingTimeInterval(30) }
            }
        }
        try Task.checkCancellation()

        var extras = TrackExtras()
        do { extras = try await catalog ?? TrackExtras() }
        catch {
            try Task.checkCancellation()
            retryAt = min(retryAt, Date().addingTimeInterval(45))
        }
        try Task.checkCancellation()
        var source = ArtworkResolution.Source.none
        var catalogImage: Data?
        let catalogArtworkURL = extras.artworkURL
        if let localURL {
            extras.artworkURL = localURL
            source = .library
        } else if let url = extras.artworkURL {
            catalogImage = try? await download(url)
            try Task.checkCancellation()
            if catalogImage != nil { source = .catalog }
            else {
                extras.artworkURL = nil
                retryAt = min(retryAt, Date().addingTimeInterval(45))
            }
        }
        if localArtwork == nil {
            // Music may expose its artwork after the initial track observation.
            retryAt = min(retryAt, Date().addingTimeInterval(45))
        } else if source == .none {
            retryAt = min(retryAt, Date().addingTimeInterval(3600))
        }
        return ArtworkResolution(extras: extras, image: localArtwork ?? catalogImage, source: source, retryAt: retryAt, uploadFailed: uploadFailed,
                                 fallbackArtworkURL: source == .library ? catalogArtworkURL : nil, uploadError: uploadError)
    }
}
