import Testing
import Foundation
@testable import AuxCore

/// Apple's Wasted search returns other songs on Heaven Or Hell, while the
/// separate album search omits Heaven Or Hell altogether.
private final class HeavenOrHellSearch: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let entity = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "entity" }?.value
        let body = entity == "song" ? """
        {"results":[{
          "trackName":"No Idea","artistName":"Don Toliver",
          "collectionName":"Heaven Or Hell","trackTimeMillis":154424,
          "artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music115/v4/a5/c2/a5/a5c2a541-9f56-7c98-eb01-3c3198267851/075679823908.jpg/100x100bb.jpg",
          "trackViewUrl":"https://music.apple.com/us/album/no-idea/1502318851?i=1502319171&uo=4",
          "collectionViewUrl":"https://music.apple.com/us/album/no-idea/1502318851?i=1502319171&uo=4"
        }]}
        """ : "{\"results\":[]}"
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

struct CatalogResolverTests {
    @Test func wastedUsesSameAlbumCoverWithoutLinkingToAnotherSong() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeavenOrHellSearch.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let track = Track(id: "wasted", title: "Wasted", artist: "Don Toliver", album: "Heaven Or Hell", duration: 171)
        // The installed version cached this miss for an hour. Upgrading must
        // recover immediately instead of inheriting that negative cache entry.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let oldCache: [String: [String: Double]] = ["US|" + track.identity: ["expiresAt": Date().addingTimeInterval(3600).timeIntervalSinceReferenceDate]]
        try JSONEncoder().encode(oldCache).write(to: directory.appendingPathComponent("catalog-v2.json"))
        let resolver = CatalogResolver(directory: directory, session: session)
        let extras = try await resolver.resolve(track, country: "US")
        #expect(extras?.artworkURL?.lastPathComponent == "600x600bb.jpg")
        #expect(extras?.trackURL == nil)
        #expect(extras?.albumURL != nil)
        #expect(extras?.albumURL?.query?.contains("i=") != true)
        let payload = PresencePayload.make(snapshot: .init(state: .playing, track: track), extras: extras, options: .init())
        #expect(payload?.assets?.large_image == extras?.artworkURL?.absoluteString)
        #expect(payload?.assets?.large_image != nil)
        #expect(payload?.details_url == nil)
        #expect(payload?.buttons == nil)
    }
}
