import Foundation

public struct ArtworkResolution: Sendable {
    public enum Source: Sendable { case library, catalog, none }
    public var extras: TrackExtras
    public var image: Data?
    public var source: Source
    public var retryAt: Date
    public var uploadFailed: Bool
}

/// Prefer the library's actual cover; catalog matching still supplies song links.
public struct ArtworkResolver: Sendable {
    private let lookup: @Sendable (Track, String) async throws -> TrackExtras?
    private let upload: @Sendable (Data) async throws -> URL
    private let download: @Sendable (URL) async throws -> Data?

    public init(catalog: CatalogResolver, uploads: CatboxArtwork, images: ArtworkService) {
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

    public func resolve(track: Track, country: String, localArtwork: Data?, uploadAllowed: Bool) async throws -> ArtworkResolution {
        try Task.checkCancellation()
        // Resolve links alongside the upload, without letting a catalog cover
        // override the library image or making a catalog outage block it.
        async let catalog = lookup(track, country)
        var localURL: URL?
        var retryAt = Date.distantFuture
        var uploadFailed = false
        if uploadAllowed, let localArtwork {
            do { localURL = try await upload(localArtwork) }
            catch {
                try Task.checkCancellation()
                uploadFailed = true
                if case CatboxError.retryAfter(let date) = error {
                    retryAt = date
                } else if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    // Another caller can cancel a shared upload. The current
                    // track should retry soon, while using the catalog cover.
                    retryAt = Date().addingTimeInterval(5)
                } else { retryAt = Date().addingTimeInterval(15 * 60) }
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
        return ArtworkResolution(extras: extras, image: localArtwork ?? catalogImage, source: source, retryAt: retryAt, uploadFailed: uploadFailed)
    }
}
