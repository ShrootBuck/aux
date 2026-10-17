import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct DiscordImageResult: Sendable {
    public var available: Bool
    public var failure: String?
    public init(available: Bool, failure: String? = nil) { self.available = available; self.failure = failure }
}

public actor ArtworkService {
    private let session: URLSession
    public init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 15
        self.session = session ?? URLSession(configuration: configuration)
    }
    public nonisolated static func thumbnail(_ data: Data, size: Int = 700, quality: Double = 0.88) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: size
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
    /// Export pixels only: no original filename, EXIF, or other source metadata.
    public nonisolated static func uploadThumbnail(_ data: Data) -> Data? {
        guard !data.isEmpty, data.count <= 20_000_000 else { return nil }
        for size in [700, 512, 320] {
            if let jpeg = thumbnail(data, size: size, quality: 0.8), jpeg.count <= 250_000 { return jpeg }
        }
        return nil
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

    /// RPC acceptance only confirms the activity, not that Discord can fetch its
    /// image. Check the media-proxy reference returned by SET_ACTIVITY itself.
    public nonisolated static func discordProxyURL(_ reference: String?) -> URL? {
        guard let reference, reference.hasPrefix("mp:external/"),
              !reference.contains("?"), !reference.contains("#"),
              !reference.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
              let url = URL(string: "https://media.discordapp.net/" + reference.dropFirst(3)),
              url.host == "media.discordapp.net" else { return nil }
        return url
    }

    public func discordImageAvailable(_ reference: String?) async -> Bool {
        await checkDiscordImage(reference).available
    }

    public func checkDiscordImage(_ reference: String?) async -> DiscordImageResult {
        guard let url = Self.discordProxyURL(reference) else {
            return .init(available: false, failure: "Discord returned no usable image reference")
        }
        do {
            let (file, response) = try await session.download(from: url)
            defer { try? FileManager.default.removeItem(at: file) }
            try Task.checkCancellation()
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { return .init(available: false, failure: "Discord image proxy HTTP \(status)") }
            guard (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0 < 20_000_000,
                  Self.thumbnail(try Data(contentsOf: file)) != nil else {
                return .init(available: false, failure: "Discord proxy returned invalid image data")
            }
            return .init(available: true)
        } catch {
            return .init(available: false, failure: "Discord image check: " + error.localizedDescription)
        }
    }
}
