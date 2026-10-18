import Foundation
import CryptoKit

public enum ArtworkUploadError: LocalizedError {
    case invalidImage, invalidResponse, unavailable
    case http(Int)
    case retryAfter(Date)
    public var errorDescription: String? {
        switch self {
        case .invalidImage: return "Artwork could not be encoded as a small JPEG."
        case .invalidResponse: return "Artwork server returned an invalid response."
        case .unavailable: return "Artwork server unavailable."
        case .http(let code): return "Artwork server returned HTTP \(code)."
        case .retryAfter: return "Artwork upload is waiting for its retry window."
        }
    }
}

/// Image-only hosting. Credentials are issued per installation, never bundled.
public actor HostedArtwork {
    public nonisolated static let baseURL = URL(string: "https://artwork.zaydkrunz.com")!
    private struct Entry: Codable { var url: URL; var checkedAt: Date }
    private struct Cache: Codable {
        var images: [String: Entry] = [:]
        var attempts: [Date] = []
        var retryAt: [String: Date] = [:]
    }
    private let cacheURL: URL
    private let session: URLSession
    private var cache = Cache()
    private var pending: [String: Task<URL, Error>] = [:]
    private let credentialURL: URL
    private var token: String?

    public init(directory: URL, session: URLSession? = nil) {
        cacheURL = directory.appendingPathComponent("hosted-artwork-v1.json")
        credentialURL = directory.appendingPathComponent("artwork-installation-v1.json")
        token = (try? Data(contentsOf: credentialURL)).flatMap { try? JSONDecoder().decode(Credential.self, from: $0).token }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        self.session = session ?? URLSession(configuration: configuration)
        if let data = try? Data(contentsOf: cacheURL), let saved = try? JSONDecoder().decode(Cache.self, from: data) {
            cache = saved
            cache.images = cache.images.filter { Self.validURL($0.value.url) }
        }
    }

    private struct Credential: Codable { let token: String }
    private struct UploadResponse: Decodable { let url: URL; let sha256: String }
    private struct Availability: Decodable { let exists: Bool }

    private func credential() async throws -> String {
        if let token { return token }
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("v1/installations"))
        request.httpMethod = "POST"
        let (data, response) = try await session.data(for: request)
        try Self.check(response)
        guard data.count <= 2048, let credential = try? JSONDecoder().decode(Credential.self, from: data),
              credential.token.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil else { throw ArtworkUploadError.invalidResponse }
        try FileManager.default.createDirectory(at: credentialURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: credentialURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credentialURL.path)
        token = credential.token
        return credential.token
    }

    private nonisolated static func check(_ response: URLResponse) throws {
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if status == 429, let value = http?.value(forHTTPHeaderField: "Retry-After"), let seconds = Double(value) {
            throw ArtworkUploadError.retryAfter(Date().addingTimeInterval(max(5, min(seconds, 86400))))
        }
        guard status == 200 || status == 201 else { throw ArtworkUploadError.http(status) }
    }

    public nonisolated static func contentHash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public func resolve(_ artwork: Data) async throws -> URL {
        try Task.checkCancellation()
        guard let jpeg = ArtworkService.uploadThumbnail(artwork) else { throw ArtworkUploadError.invalidImage }
        let hash = Self.contentHash(jpeg)
        if let task = pending[hash] { return try await Self.wait(for: task) }
        let task = Task { try await self.resolvePrepared(jpeg, hash: hash) }
        pending[hash] = task
        defer { pending[hash] = nil }
        return try await Self.wait(for: task)
    }

    private nonisolated static func wait(for task: Task<URL, Error>) async throws -> URL {
        try await withTaskCancellationHandler {
            let url = try await task.value
            try Task.checkCancellation()
            return url
        } onCancel: { task.cancel() }
    }

    private func resolvePrepared(_ jpeg: Data, hash: String) async throws -> URL {
        try Task.checkCancellation()
        if var entry = cache.images[hash] {
            // Image URLs are cached for a year at the CDN. Ask the origin's
            // uncached status endpoint on every reuse, including fresh entries.
            let key = entry.url.deletingPathExtension().lastPathComponent
            var request = URLRequest(url: Self.baseURL.appendingPathComponent("v1/artwork/\(key)/status"),
                                     cachePolicy: .reloadIgnoringLocalCacheData)
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            let exists: Bool?
            do {
                let (data, response) = try await session.data(for: request)
                exists = (response as? HTTPURLResponse)?.statusCode == 200 && data.count <= 2048
                    ? (try? JSONDecoder().decode(Availability.self, from: data))?.exists : nil
            } catch {
                try Task.checkCancellation()
                exists = nil
            }
            try Task.checkCancellation()
            if exists != false {
                // Only an explicit missing image triggers an upload. Network or
                // server failures keep the URL and are checked again next time.
                if exists == true { entry.checkedAt = Date() }
                cache.images[hash] = entry
                save()
                return entry.url
            }
            cache.images[hash] = nil
            save()
        }
        let now = Date()
        if let next = cache.retryAt[hash], next > now { throw ArtworkUploadError.retryAfter(next) }
        cache.attempts.removeAll { now.timeIntervalSince($0) >= 86400 }
        let hourly = cache.attempts.filter { now.timeIntervalSince($0) < 3600 }.sorted()
        // Courtesy limits apply to attempts, including failures and canceled
        // uploads. They persist across restarts, but aren't server security.
        if cache.attempts.count >= 200, let first = cache.attempts.min() {
            throw ArtworkUploadError.retryAfter(first.addingTimeInterval(86400))
        }
        if hourly.count >= 60, let first = hourly.first {
            throw ArtworkUploadError.retryAfter(first.addingTimeInterval(3600))
        }
        if let last = cache.attempts.max(), now.timeIntervalSince(last) < 5 {
            throw ArtworkUploadError.retryAfter(last.addingTimeInterval(5))
        }
        cache.attempts.append(now)
        save()
        // Uploads are idempotent on the server. Persist a short failure cooldown.
        cache.retryAt[hash] = now.addingTimeInterval(30)
        save()
        let result: UploadResponse
        do {
            let credential = try await credential()
            try Task.checkCancellation()
            var request = URLRequest(url: Self.baseURL.appendingPathComponent("v1/artwork"))
            request.httpMethod = "POST"
            request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer " + credential, forHTTPHeaderField: "Authorization")
            request.setValue("Aux/0.4", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.upload(for: request, from: jpeg)
            try Self.check(response)
            guard data.count <= 2048, let decoded = try? JSONDecoder().decode(UploadResponse.self, from: data),
                  Self.validURL(decoded.url), decoded.url.lastPathComponent == decoded.sha256 + ".jpg" else { throw ArtworkUploadError.invalidResponse }
            result = decoded
        } catch {
            if case ArtworkUploadError.retryAfter(let date) = error { cache.retryAt[hash] = date }
            else if Task.isCancelled { cache.retryAt[hash] = Date().addingTimeInterval(5) }
            save()
            throw error
        }
        let url = result.url
        // Save an accepted upload even if its caller has just changed tracks.
        cache.images[hash] = Entry(url: url, checkedAt: Date())
        cache.retryAt[hash] = nil
        save()
        return url
    }

    private nonisolated static func validURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == baseURL.host &&
        url.user == nil && url.password == nil && url.port == nil && url.query == nil && url.fragment == nil &&
        url.path.range(of: "^/covers/[a-f0-9]{64}\\.jpg$", options: .regularExpression) != nil
    }

    private func save() {
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(cache) { try? data.write(to: cacheURL, options: .atomic) }
    }
}
