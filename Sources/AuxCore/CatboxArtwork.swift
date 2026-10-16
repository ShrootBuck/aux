import Foundation
import CryptoKit

public enum CatboxError: Error {
    case invalidImage, invalidResponse, unavailable
    case retryAfter(Date)
}

/// Optional direct uploads. No Aux server, account, or bundled upload credential.
public actor CatboxArtwork {
    private struct Entry: Codable { var url: URL; var checkedAt: Date }
    private struct Cache: Codable {
        var images: [String: Entry] = [:]
        var attempts: [Date] = []
    }
    private let cacheURL: URL
    private let session: URLSession
    private var cache = Cache()
    private var pending: [String: Task<URL, Error>] = [:]
    private var retryAt: [String: Date] = [:]

    public init(directory: URL, session: URLSession? = nil) {
        cacheURL = directory.appendingPathComponent("catbox-v1.json")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        self.session = session ?? URLSession(configuration: configuration)
        if let data = try? Data(contentsOf: cacheURL), let saved = try? JSONDecoder().decode(Cache.self, from: data) {
            cache = saved
            cache.images = cache.images.filter { Self.validURL($0.value.url) }
        }
    }

    public nonisolated static func contentHash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public func resolve(_ artwork: Data) async throws -> URL {
        try Task.checkCancellation()
        guard let jpeg = ArtworkService.uploadThumbnail(artwork) else { throw CatboxError.invalidImage }
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
            if Date().timeIntervalSince(entry.checkedAt) < 30 * 86400 { return entry.url }
            // Only a definite deletion triggers another upload. A temporary
            // network failure must not create more copies of a stored cover.
            var request = URLRequest(url: entry.url)
            request.httpMethod = "HEAD"
            let status: Int?
            do {
                let (_, response) = try await session.data(for: request)
                status = (response as? HTTPURLResponse)?.statusCode
            } catch {
                try Task.checkCancellation()
                status = nil
            }
            try Task.checkCancellation()
            if status != 404 && status != 410 {
                // Retry transient failures in a day instead of on every song.
                entry.checkedAt = Date().addingTimeInterval(status == 200 ? 0 : -29 * 86400)
                cache.images[hash] = entry
                save()
                return entry.url
            }
            cache.images[hash] = nil
            save()
        }
        let now = Date()
        if let next = retryAt[hash], next > now { throw CatboxError.retryAfter(next) }
        cache.attempts.removeAll { now.timeIntervalSince($0) >= 86400 }
        let hourly = cache.attempts.filter { now.timeIntervalSince($0) < 3600 }.sorted()
        // Courtesy limits apply to attempts, including failures and canceled
        // uploads. They persist across restarts, but aren't server security.
        if cache.attempts.count >= 200, let first = cache.attempts.min() {
            throw CatboxError.retryAfter(first.addingTimeInterval(86400))
        }
        if hourly.count >= 60, let first = hourly.first {
            throw CatboxError.retryAfter(first.addingTimeInterval(3600))
        }
        if let last = cache.attempts.max(), now.timeIntervalSince(last) < 5 {
            throw CatboxError.retryAfter(last.addingTimeInterval(5))
        }
        cache.attempts.append(now)
        save()
        // If the connection dies after Catbox accepted the file, don't retry
        // immediately: a failed response doesn't prove the upload failed.
        retryAt[hash] = now.addingTimeInterval(15 * 60)

        let boundary = "Aux-" + UUID().uuidString
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"reqtype\"\r\n\r\nfileupload\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"fileToUpload\"; filename=\"\(hash).jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8)
        body.append(jpeg)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: URL(string: "https://catbox.moe/user/api.php")!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Aux/0.2", forHTTPHeaderField: "User-Agent")
        let result: (Data, URLResponse)
        do { result = try await session.upload(for: request, from: body) }
        catch {
            if Task.isCancelled { retryAt[hash] = Date().addingTimeInterval(5) }
            throw error
        }
        let (data, response) = result
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CatboxError.unavailable }
        guard data.count <= 1024, let text = String(data: data, encoding: .utf8),
              let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), Self.validURL(url) else {
            throw CatboxError.invalidResponse
        }
        // Save an accepted upload even if its caller has just changed tracks.
        cache.images[hash] = Entry(url: url, checkedAt: Date())
        retryAt[hash] = nil
        save()
        return url
    }

    private nonisolated static func validURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "files.catbox.moe" &&
        url.user == nil && url.password == nil && url.port == nil && url.query == nil && url.fragment == nil &&
        url.path.range(of: "^/[a-zA-Z0-9]+\\.jpg$", options: .regularExpression) != nil
    }

    private func save() {
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(cache) { try? data.write(to: cacheURL, options: .atomic) }
    }
}
