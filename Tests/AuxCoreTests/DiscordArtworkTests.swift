import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import AuxCore

private final class DiscordImageStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.lastPathComponent
        let status = path == "broken.jpg" ? 502 : 200
        var body = Data("{\"message\":\"Invalid resource\"}".utf8)
        if path == "valid.jpg" {
            let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            let data = NSMutableData()
            let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, context.makeImage()!, nil)
            CGImageDestinationFinalize(destination)
            body = data as Data
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                                            headerFields: ["Content-Type": "image/jpeg"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

struct DiscordArtworkTests {
    @Test func proxyReferenceUsesDiscordHostAndPreservesEncodedSourceQuery() {
        let reference = "mp:external/hash/%3Faux%3D1/https/files.catbox.moe/cover.jpg"
        #expect(ArtworkService.discordProxyURL(reference)?.absoluteString == "https://media.discordapp.net/external/hash/%3Faux%3D1/https/files.catbox.moe/cover.jpg")
    }

    @Test(arguments: [nil, "", "https://files.catbox.moe/cover.jpg", "mp:https://evil.test/cover.jpg", "mp:external/hash/cover.jpg?redirect=1", "mp:external/hash/cover.jpg#fragment", "mp:external/hash/cover\n.jpg"] as [String?])
    func invalidReferencesAreNotFetched(_ reference: String?) {
        #expect(ArtworkService.discordProxyURL(reference) == nil)
    }

    @Test func onlyDecodableSuccessfulProxyResponsesCountAsAvailable() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DiscordImageStub.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let service = ArtworkService(session: session)
        #expect(await service.discordImageAvailable("mp:external/hash/https/files.catbox.moe/valid.jpg"))
        #expect(await !service.discordImageAvailable("mp:external/hash/https/files.catbox.moe/broken.jpg"))
        // Even HTTP 200 with an image content type can contain an error body.
        #expect(await !service.discordImageAvailable("mp:external/hash/https/files.catbox.moe/not-image.jpg"))
        #expect(await !service.discordImageAvailable(nil))
    }
}
