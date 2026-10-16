import Foundation
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

public actor ArtworkService {
    private let session: URLSession
    private var uploads: [String: (url: URL, expires: Date)] = [:]
    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 15
        session = URLSession(configuration: configuration)
    }
    public nonisolated static func thumbnail(_ data: Data, size: Int = 700) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: size
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
    public func download(_ url: URL) async throws -> Data? {
        guard url.scheme == "https" else { return nil }
        let (file, response) = try await session.download(from: url)
        defer { try? FileManager.default.removeItem(at: file) }
        try Task.checkCancellation()
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0 < 20_000_000 else { return nil }
        return Self.thumbnail(try Data(contentsOf: file))
    }
    /// Called only after explicit opt-in and only for a track eligible for sharing.
    public func upload(_ data: Data) async throws -> URL {
        guard let jpeg = Self.thumbnail(data, size: 512) else { throw URLError(.cannotDecodeContentData) }
        let key = SHA256.hash(data: jpeg).map { String(format: "%02x", $0) }.joined()
        if let entry = uploads[key], entry.expires > Date() { return entry.url }
        let boundary = "Aux-\(UUID().uuidString)"
        var body = Data()
        func add(_ string: String) { body.append(Data(string.utf8)) }
        for (name, value) in [("reqtype", "fileupload"), ("time", "1h")] {
            add("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"fileToUpload\"; filename=\"cover.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n")
        body.append(jpeg)
        add("\r\n--\(boundary)--\r\n")
        var request = URLRequest(url: URL(string: "https://litterbox.catbox.moe/resources/internals/api.php")!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (responseData, response) = try await session.upload(for: request, from: body)
        try Task.checkCancellation()
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: responseData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: text), url.scheme == "https", url.host == "litter.catbox.moe" else { throw URLError(.badServerResponse) }
        uploads = uploads.filter { $0.value.expires > Date() }
        uploads[key] = (url, Date().addingTimeInterval(55 * 60))
        return url
    }
}
