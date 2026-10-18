import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import AuxCore

private final class ArtworkUploadStub: URLProtocol {
    private static let lock = NSLock()
    private static var handler: (URLRequest) -> (Int, String) = { _ in (200, "{\"url\":\"https://artwork.zaydkrunz.com/covers/" + String(repeating: "a", count: 64) + ".jpg\",\"sha256\":\"" + String(repeating: "a", count: 64) + "\"}") }
    private static var requests: [URLRequest] = []
    private static var bodies: [Data] = []
    private static var responseDelay: TimeInterval = 0
    private let stopLock = NSLock()
    private var stopped = false

    static func reset(delay: TimeInterval = 0, handler: @escaping (URLRequest) -> (Int, String) = { _ in (200, "{\"url\":\"https://artwork.zaydkrunz.com/covers/" + String(repeating: "a", count: 64) + ".jpg\",\"sha256\":\"" + String(repeating: "a", count: 64) + "\"}") }) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler; requests = []; bodies = []; responseDelay = delay
    }
    static var recorded: ([URLRequest], [Data]) {
        lock.lock(); defer { lock.unlock() }
        return (requests, bodies)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                body.append(contentsOf: bytes.prefix(count))
            }
        }
        Self.lock.lock()
        if request.url?.lastPathComponent != "installations" { Self.requests.append(request); Self.bodies.append(body) }
        let handler = Self.handler; let delay = request.url?.lastPathComponent == "installations" ? 0 : Self.responseDelay
        Self.lock.unlock()
        let (status, text) = request.url?.lastPathComponent == "installations"
            ? (201, "{\"token\":\"" + String(repeating: "t", count: 43) + "\"}") : handler(request)
        let delivery = DispatchWorkItem { [self] in
            stopLock.lock(); defer { stopLock.unlock() }
            guard !stopped else { return }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: delivery)
    }
    override func stopLoading() {
        stopLock.lock(); stopped = true; stopLock.unlock()
    }
}

@Suite(.serialized)
struct HostedArtworkTests {
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArtworkUploadStub.self]
        return URLSession(configuration: configuration)
    }
    private func artwork(red: CGFloat = 0.3, size: Int = 64) throws -> Data {
        let context = try #require(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: red, green: 0.2, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "private source metadata"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 1.0, kCGImagePropertyGPSLatitudeRef: "N"]
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func seed(_ directory: URL, image: Data, attempts: [Date] = []) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let hash = HostedArtwork.contentHash(try #require(ArtworkService.uploadThumbnail(image)))
        let cache: [String: Any] = [
            "images": [hash: ["url": "https://artwork.zaydkrunz.com/covers/" + String(repeating: "b", count: 64) + ".jpg", "checkedAt": Date().timeIntervalSinceReferenceDate]],
            "attempts": attempts.map(\.timeIntervalSinceReferenceDate), "retryAt": [:]
        ]
        try JSONSerialization.data(withJSONObject: cache).write(to: directory.appendingPathComponent("hosted-artwork-v1.json"))
    }

    @Test func resizedUploadHasNoSourceMetadata() throws {
        let original = try artwork(size: 1400)
        let originalSource = try #require(CGImageSourceCreateWithData(original as CFData, nil))
        let originalProperties = try #require(CGImageSourceCopyPropertiesAtIndex(originalSource, 0, nil) as? [String: Any])
        #expect(originalProperties[kCGImagePropertyGPSDictionary as String] != nil)
        let originalExif = originalProperties[kCGImagePropertyExifDictionary as String] as? [String: Any]
        #expect(originalExif?[kCGImagePropertyExifUserComment as String] != nil)
        let jpeg = try #require(ArtworkService.uploadThumbnail(original))
        #expect(jpeg.count <= 250_000)
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        #expect(properties[kCGImagePropertyPixelWidth as String] as? Int == 700)
        #expect(properties[kCGImagePropertyPixelHeight as String] as? Int == 700)
        #expect(properties[kCGImagePropertyGPSDictionary as String] == nil)
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
        #expect(exif?[kCGImagePropertyExifUserComment as String] == nil)
        // ImageIO adds new dimensions/color-space tags to the exported JPEG.
        // Only those generated technical fields may remain in EXIF.
        let exifKeys = Set(exif?.keys.map { $0 } ?? [])
        #expect(exifKeys.isSubset(of: [kCGImagePropertyExifColorSpace as String, kCGImagePropertyExifPixelXDimension as String, kCGImagePropertyExifPixelYDimension as String]))
        #expect(HostedArtwork.contentHash(jpeg) != HostedArtwork.contentHash(try #require(ArtworkService.uploadThumbnail(artwork(red: 0.8)))))
    }

    @Test func identicalArtworkAcrossTracksAndRestartsUploadsOnlyOnce() async throws {
        ArtworkUploadStub.reset(delay: 0.05)
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let session = session(); defer { session.invalidateAndCancel() }
        let uploader = HostedArtwork(directory: directory, session: session)
        let image = try artwork()
        async let first = uploader.resolve(image)
        async let second = uploader.resolve(image)
        let (a, b) = try await (first, second)
        #expect(a == b)
        let restored = HostedArtwork(directory: directory, session: session)
        #expect(try await restored.resolve(image) == a)
        let (requests, bodies) = ArtworkUploadStub.recorded
        #expect(requests.map(\.httpMethod) == ["POST", "GET"])
        #expect(requests.first?.httpMethod == "POST")
        #expect(requests.first?.url?.absoluteString == "https://artwork.zaydkrunz.com/v1/artwork")
        #expect(bodies.first == ArtworkService.uploadThumbnail(image))
        #expect(requests.first?.value(forHTTPHeaderField: "Content-Type") == "image/jpeg")
        #expect(requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer " + String(repeating: "t", count: 43))
    }

    @Test func uploadFailureBacksOffAndAttemptsSurviveRestart() async throws {
        ArtworkUploadStub.reset { _ in (503, "unavailable") }
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let session = session(); defer { session.invalidateAndCancel() }
        let uploader = HostedArtwork(directory: directory, session: session)
        let image = try artwork()
        await #expect(throws: (any Error).self) { try await uploader.resolve(image) }
        await #expect(throws: ArtworkUploadError.self) { try await uploader.resolve(image) }
        let restored = HostedArtwork(directory: directory, session: session)
        await #expect(throws: ArtworkUploadError.self) { try await restored.resolve(image) }
        #expect(ArtworkUploadStub.recorded.0.count == 1)
    }

    @Test(arguments: ["https://example.com/a.jpg", "https://files.catbox.moe.evil.test/a.jpg", "https://files.catbox.moe/a.html", "http://files.catbox.moe/a.jpg", "<html>Error</html>"])
    func unexpectedResponseNeverBecomesArtwork(_ response: String) async throws {
        ArtworkUploadStub.reset { _ in (200, response) }
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let session = session(); defer { session.invalidateAndCancel() }
        let uploader = HostedArtwork(directory: directory, session: session)
        await #expect(throws: ArtworkUploadError.self) { try await uploader.resolve(artwork()) }
    }

    @Test func freshlyCachedImageIsReuploadedImmediatelyWhenPurged() async throws {
        ArtworkUploadStub.reset { request in request.url?.lastPathComponent == "status" ? (200, "{\"exists\":false}") : (200, "{\"url\":\"https://artwork.zaydkrunz.com/covers/" + String(repeating: "a", count: 64) + ".jpg\",\"sha256\":\"" + String(repeating: "a", count: 64) + "\"}") }
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let image = try artwork(); try seed(directory, image: image)
        let session = session(); defer { session.invalidateAndCancel() }
        let url = try await HostedArtwork(directory: directory, session: session).resolve(image)
        #expect(url.lastPathComponent == String(repeating: "a", count: 64) + ".jpg")
        let requests = ArtworkUploadStub.recorded.0
        #expect(requests.map(\.httpMethod) == ["GET", "POST"])
        #expect(requests.first?.url?.path == "/v1/artwork/" + String(repeating: "b", count: 64) + "/status")
        #expect(requests.first?.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(requests.first?.value(forHTTPHeaderField: "Cache-Control") == "no-cache")
    }

    @Test(arguments: [200, 404, 503])
    func uncertainOriginStatusKeepsCachedURLAndRechecksOnNextUse(_ status: Int) async throws {
        ArtworkUploadStub.reset { _ in (status, "invalid or unavailable") }
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let image = try artwork(); try seed(directory, image: image)
        let session = session(); defer { session.invalidateAndCancel() }
        let url = try await HostedArtwork(directory: directory, session: session).resolve(image)
        #expect(url.lastPathComponent == String(repeating: "b", count: 64) + ".jpg")
        #expect(try await HostedArtwork(directory: directory, session: session).resolve(image) == url)
        #expect(ArtworkUploadStub.recorded.0.map(\.httpMethod) == ["GET", "GET"])
    }

    @Test func everyCachedReuseChecksOriginWithoutUploadingExistingArtwork() async throws {
        ArtworkUploadStub.reset { _ in (200, "{\"exists\":true}") }
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let image = try artwork(); try seed(directory, image: image)
        let session = session(); defer { session.invalidateAndCancel() }
        let uploader = HostedArtwork(directory: directory, session: session)
        let first = try await uploader.resolve(image)
        #expect(try await uploader.resolve(image) == first)
        #expect(ArtworkUploadStub.recorded.0.map(\.httpMethod) == ["GET", "GET"])
    }

    @Test func hourlyBudgetRejectsNewUploadsAfterRestart() async throws {
        ArtworkUploadStub.reset()
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let image = try artwork()
        try seed(directory, image: image, attempts: Array(repeating: Date().addingTimeInterval(-10), count: 60))
        let session = session(); defer { session.invalidateAndCancel() }
        let uploader = HostedArtwork(directory: directory, session: session)
        await #expect(throws: ArtworkUploadError.self) { try await uploader.resolve(artwork(red: 0.8)) }
        #expect(ArtworkUploadStub.recorded.0.isEmpty)
    }

    @Test func invalidImagesNeverUpload() async throws {
        ArtworkUploadStub.reset()
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let session = session(); defer { session.invalidateAndCancel() }
        let uploader = HostedArtwork(directory: directory, session: session)
        await #expect(throws: ArtworkUploadError.self) { try await uploader.resolve(Data("not an image".utf8)) }
        #expect(ArtworkUploadStub.recorded.0.isEmpty)
    }

    @Test func cancelingEnrichmentCancelsTheUpload() async throws {
        ArtworkUploadStub.reset(delay: 0.5)
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let session = session(); defer { session.invalidateAndCancel() }
        let uploader = HostedArtwork(directory: directory, session: session)
        let image = try artwork()
        let task = Task { try await uploader.resolve(image) }
        for _ in 0..<100 {
            if !ArtworkUploadStub.recorded.0.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(ArtworkUploadStub.recorded.0.count == 1)
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        let cache = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("hosted-artwork-v1.json"))) as? [String: Any]
        #expect((cache?["images"] as? [String: Any])?.isEmpty == true)
    }
}
