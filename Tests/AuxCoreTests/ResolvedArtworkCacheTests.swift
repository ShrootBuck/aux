import Testing
import Foundation
@testable import AuxCore

struct ResolvedArtworkCacheTests {
    private let first = Track(id: "i-know", title: "I KNOW ?", artist: "Travis Scott", album: "UTOPIA", duration: 211)
    private let second = Track(id: "gasolina", title: "Gasolina", artist: "Daddy Yankee", album: "Barrio Fino", duration: 192)
    private let firstURL = URL(string: "https://artwork.zaydkrunz.com/covers/" + String(repeating: "a", count: 64) + ".jpg")!
    private let secondURL = URL(string: "https://artwork.zaydkrunz.com/covers/" + String(repeating: "b", count: 64) + ".jpg")!

    private func resolution(_ url: URL, retryAt: Date = .distantFuture) -> ArtworkResolution {
        .init(extras: .init(artworkURL: url), image: Data([1, 2, 3]), source: .library,
              retryAt: retryAt, uploadFailed: false)
    }

    @Test func returningToKnownTrackIncludesCorrectCoverInFirstDiscordPayload() throws {
        var cache = ResolvedArtworkCache()
        cache.store(resolution(firstURL), localArtwork: Data([4]), for: first.identity)
        cache.store(resolution(secondURL), localArtwork: Data([5]), for: second.identity)
        for (track, expected) in [(first, firstURL), (second, secondURL), (first, firstURL)] {
            let cached = cache.entry(for: track.identity)
            let ready = try #require(cached)
            let payload = try #require(PresencePayload.make(snapshot: .init(state: .playing, track: track),
                                                          extras: ready.resolution.extras, options: .init()))
            #expect(payload.details == track.title)
            #expect(payload.assets?.large_image == expected.absoluteString)
            #expect(ready.complete)
        }
    }

    @Test func settingsContextsStaySeparateAndExpiredFailuresKeepCoverWhileRetrying() {
        var cache = ResolvedArtworkCache()
        let now = Date()
        cache.store(resolution(firstURL), localArtwork: Data([1]), for: "song|US|true|true")
        #expect(cache.entry(for: "song|US|false|false") == nil)
        #expect(cache.entry(for: "song|GB|true|true") == nil)
        cache.store(resolution(secondURL, retryAt: now), localArtwork: nil, for: "retry")
        let retry = cache.entry(for: "retry", at: now)
        #expect(retry?.resolution.extras.artworkURL == secondURL)
        #expect(retry?.complete == false)
        #expect(cache.entry(for: "song|US|true|true", at: now) != nil)
    }

    @Test func earlyCoverRemainsUsableWhileCatalogEnrichmentIsIncomplete() throws {
        var cache = ResolvedArtworkCache()
        cache.store(resolution(firstURL), localArtwork: Data([1]), for: first.identity, complete: false)
        let cached = cache.entry(for: first.identity)
        let ready = try #require(cached)
        #expect(ready.resolution.extras.artworkURL == firstURL)
        #expect(!ready.complete)
        cache.store(resolution(firstURL), localArtwork: Data([1]), for: first.identity)
        #expect(cache.entry(for: first.identity)?.complete == true)
    }

    @Test func memoryIsBoundedAndMissingArtworkInvalidatesAllMatchingTracks() {
        var cache = ResolvedArtworkCache(capacity: 2)
        cache.store(resolution(firstURL), localArtwork: nil, for: "a")
        cache.store(resolution(secondURL), localArtwork: nil, for: "b")
        _ = cache.entry(for: "a")
        cache.store(resolution(firstURL), localArtwork: nil, for: "c")
        #expect(cache.entry(for: "b") == nil)
        cache.remove(artworkURL: firstURL)
        #expect(cache.entry(for: "a") == nil)
        #expect(cache.entry(for: "c") == nil)
    }
}
