import Testing
import Foundation
@testable import AuxCore

private actor ArtworkRequests {
    private(set) var uploads = 0
    private(set) var downloads = 0
    func uploaded() { uploads += 1 }
    func downloaded() { downloads += 1 }
}

struct ArtworkResolverTests {
    private let track = Track(id: "library-song", title: "Song", artist: "Artist", album: "Album", duration: 180)
    private let local = Data("library cover pixels".utf8)
    private let remote = Data("different catalog cover pixels".utf8)
    private let localURL = URL(string: "https://files.catbox.moe/library.jpg")!
    private let catalogURL = URL(string: "https://is1-ssl.mzstatic.com/catalog.jpg")!
    private var catalogExtras: TrackExtras {
        .init(artworkURL: catalogURL, trackURL: URL(string: "https://music.apple.com/us/album/song/123?i=456"), albumURL: URL(string: "https://music.apple.com/us/album/album/123"))
    }

    @Test func libraryCoverPublishesBeforeSlowCatalogLookupCompletes() async throws {
        let gate = ArtworkGate()
        let resolver = ArtworkResolver(
            lookup: { _, _ in
                // This would deadlock if the library callback waited for catalog.
                for _ in 0..<100 {
                    if await gate.published { return catalogExtras }
                    try await Task.sleep(for: .milliseconds(5))
                }
                Issue.record("Catalog was awaited before publishing the cover")
                return catalogExtras
            }, upload: { _ in localURL }, download: { _ in remote })
        let result = try await resolver.resolve(track: track, country: "US", localArtwork: local, uploadAllowed: true) { url in
            #expect(url == localURL)
            await gate.publish()
        }
        #expect(await gate.published)
        #expect(result.extras.trackURL == catalogExtras.trackURL)
    }

    @Test func libraryCoverWinsOverDifferentCatalogCoverAndKeepsListeningLinks() async throws {
        let requests = ArtworkRequests()
        let resolver = ArtworkResolver(
            lookup: { _, _ in catalogExtras },
            upload: { image in
                #expect(image == local)
                await requests.uploaded()
                return localURL
            },
            download: { _ in await requests.downloaded(); return remote }
        )
        let result = try await resolver.resolve(track: track, country: "US", localArtwork: local, uploadAllowed: true)
        #expect(result.source == .library)
        #expect(result.image == local)
        #expect(result.extras.artworkURL == localURL)
        #expect(result.fallbackArtworkURL == catalogURL)
        #expect(result.extras.trackURL == catalogExtras.trackURL)
        #expect(result.extras.albumURL == catalogExtras.albumURL)
        #expect(result.retryAt.timeIntervalSinceNow > 55 && result.retryAt.timeIntervalSinceNow <= 60)
        #expect(await requests.uploads == 1)
        #expect(await requests.downloads == 0)
        let payload = PresencePayload.make(snapshot: .init(state: .playing, track: track), extras: result.extras, options: .init())
        #expect(payload?.assets?.large_image == localURL.absoluteString)
        #expect(payload?.details_url == catalogExtras.trackURL?.absoluteString)
    }

    @Test func missingLibraryCoverFallsBackAndRechecksMusicLater() async throws {
        let requests = ArtworkRequests()
        let resolver = ArtworkResolver(
            lookup: { _, _ in catalogExtras },
            upload: { _ in await requests.uploaded(); return localURL },
            download: { _ in await requests.downloaded(); return remote }
        )
        let result = try await resolver.resolve(track: track, country: "US", localArtwork: nil, uploadAllowed: true)
        #expect(result.source == .catalog)
        #expect(result.image == remote)
        #expect(result.extras.artworkURL == catalogURL)
        #expect(result.fallbackArtworkURL == nil)
        #expect(result.retryAt.timeIntervalSinceNow > 0 && result.retryAt.timeIntervalSinceNow <= 45)
        #expect(await requests.uploads == 0)
        #expect(await requests.downloads == 1)
    }

    @Test func uploadsDisabledUsesCatalogAndKeepsLocalPanelImage() async throws {
        let requests = ArtworkRequests()
        let resolver = ArtworkResolver(
            lookup: { _, _ in catalogExtras },
            upload: { _ in await requests.uploaded(); return localURL },
            download: { _ in remote }
        )
        let result = try await resolver.resolve(track: track, country: "US", localArtwork: local, uploadAllowed: false)
        #expect(result.source == .catalog)
        #expect(result.image == local)
        #expect(result.extras.artworkURL == catalogURL)
        #expect(await requests.uploads == 0)
        #expect(!result.uploadFailed)
    }

    @Test(arguments: [ArtworkUploadError.unavailable, .invalidImage, .invalidResponse])
    func uploadFailureUsesCatalogWithoutLosingRetry(_ error: ArtworkUploadError) async throws {
        let resolver = ArtworkResolver(lookup: { _, _ in catalogExtras }, upload: { _ in throw error }, download: { _ in remote })
        let result = try await resolver.resolve(track: track, country: "US", localArtwork: local, uploadAllowed: true)
        #expect(result.source == .catalog)
        #expect(result.extras.artworkURL == catalogURL)
        #expect(result.image == local)
        #expect(result.uploadFailed)
        #expect(result.retryAt.timeIntervalSinceNow > 25 && result.retryAt.timeIntervalSinceNow <= 30)
    }

    @Test func rateLimitDeadlineSurvivesSuccessfulCatalogFallback() async throws {
        let deadline = Date().addingTimeInterval(120)
        let resolver = ArtworkResolver(lookup: { _, _ in catalogExtras }, upload: { _ in throw ArtworkUploadError.retryAfter(deadline) }, download: { _ in remote })
        let result = try await resolver.resolve(track: track, country: "US", localArtwork: local, uploadAllowed: true)
        #expect(result.source == .catalog)
        #expect(result.retryAt == deadline)
    }

    @Test func catalogOutageDoesNotDiscardLibraryCover() async throws {
        let requests = ArtworkRequests()
        let resolver = ArtworkResolver(
            lookup: { _, _ in throw URLError(.notConnectedToInternet) },
            upload: { _ in localURL },
            download: { _ in await requests.downloaded(); return nil }
        )
        let result = try await resolver.resolve(track: track, country: "US", localArtwork: local, uploadAllowed: true)
        #expect(result.source == .library)
        #expect(result.extras.artworkURL == localURL)
        #expect(result.extras.trackURL == nil)
        #expect(await requests.downloads == 0)
    }

    @Test func brokenCatalogCoverIsNotPublishedWhenLocalUploadAlsoFails() async throws {
        let resolver = ArtworkResolver(lookup: { _, _ in catalogExtras }, upload: { _ in throw ArtworkUploadError.unavailable }, download: { _ in nil })
        let result = try await resolver.resolve(track: track, country: "US", localArtwork: local, uploadAllowed: true)
        #expect(result.source == .none)
        #expect(result.extras.artworkURL == nil)
        #expect(result.extras.trackURL == catalogExtras.trackURL)
        #expect(result.image == local)
        #expect(result.retryAt.timeIntervalSinceNow > 0 && result.retryAt.timeIntervalSinceNow <= 45)
    }

    @Test func missingBothCoversStillReturnsListeningLinks() async throws {
        var metadata = catalogExtras
        metadata.artworkURL = nil
        let links = metadata
        let resolver = ArtworkResolver(lookup: { _, _ in links }, upload: { _ in localURL }, download: { _ in remote })
        let result = try await resolver.resolve(track: track, country: "US", localArtwork: nil, uploadAllowed: true)
        #expect(result.source == .none)
        #expect(result.image == nil)
        #expect(result.extras.artworkURL == nil)
        #expect(result.extras.trackURL == links.trackURL)
    }

    @Test func canceledTrackDoesNotContinueToCatalogImageOrReturnArtwork() async throws {
        let requests = ArtworkRequests()
        let resolver = ArtworkResolver(
            lookup: { _, _ in catalogExtras },
            upload: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                throw CancellationError()
            },
            download: { _ in await requests.downloaded(); return remote }
        )
        let task = Task { try await resolver.resolve(track: track, country: "US", localArtwork: local, uploadAllowed: true) }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await requests.downloads == 0)
    }

    @Test func sharedUploadCancellationUsesFallbackAndRetriesSoon() async throws {
        let resolver = ArtworkResolver(lookup: { _, _ in catalogExtras }, upload: { _ in throw CancellationError() }, download: { _ in remote })
        let result = try await resolver.resolve(track: track, country: "US", localArtwork: local, uploadAllowed: true)
        #expect(result.source == .catalog)
        #expect(result.retryAt.timeIntervalSinceNow > 0 && result.retryAt.timeIntervalSinceNow <= 5)
    }
}

private actor ArtworkGate {
    private(set) var published = false
    func publish() { published = true }
}
