import Foundation

public struct CatalogResult: Codable, Equatable, Sendable {
    public var trackName: String?
    public var artistName: String?
    public var collectionName: String?
    public var trackTimeMillis: Double?
    public var artworkUrl100: URL?
    public var trackViewUrl: URL?
    public var artistViewUrl: URL?
    public var collectionViewUrl: URL?

    public init(trackName: String, artistName: String, collectionName: String, trackTimeMillis: Double? = nil, artworkUrl100: URL? = nil, trackViewUrl: URL? = nil) {
        self.trackName = trackName; self.artistName = artistName; self.collectionName = collectionName
        self.trackTimeMillis = trackTimeMillis; self.artworkUrl100 = artworkUrl100; self.trackViewUrl = trackViewUrl
    }
}

public enum CatalogMatcher {
    /// An album cover does not identify a recording. Keep song links strict,
    /// but allow the same album's cover when remaster titles or durations differ.
    public static func albumMatch(for track: Track, results: [CatalogResult]) -> CatalogResult? {
        guard !normalize(track.artist).isEmpty, !normalize(track.album).isEmpty else { return nil }
        return results.first {
            normalize($0.artistName ?? "") == normalize(track.artist) &&
            normalize($0.collectionName ?? "") == normalize(track.album) &&
            $0.artworkUrl100?.scheme == "https" &&
            ($0.artworkUrl100?.host?.hasSuffix(".mzstatic.com") == true)
        }
    }
    public static func normalize(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
    public static func bestMatch(for track: Track, results: [CatalogResult]) -> CatalogResult? {
        // Versions matter. Don't strip "live", "remix", "deluxe", etc. A single
        // search hit must pass exactly the same checks as a page full of hits.
        guard !normalize(track.artist).isEmpty, !normalize(track.album).isEmpty else { return nil }
        return results.filter {
            normalize($0.trackName ?? "") == normalize(track.title) &&
            normalize($0.artistName ?? "") == normalize(track.artist) &&
            normalize($0.collectionName ?? "") == normalize(track.album) &&
            (track.duration <= 0 || $0.trackTimeMillis == nil || abs(($0.trackTimeMillis! / 1000) - track.duration) <= 3)
        }.min {
            abs(($0.trackTimeMillis ?? track.duration * 1000) / 1000 - track.duration) < abs(($1.trackTimeMillis ?? track.duration * 1000) / 1000 - track.duration)
        }
    }
}

public actor CatalogResolver {
    private struct Entry: Codable { var extras: TrackExtras?; var expiresAt: Date }
    private struct Response: Decodable { var results: [CatalogResult] }
    private var entries: [String: Entry] = [:]
    private let cacheURL: URL
    private let session: URLSession
    private var nextRequest = Date.distantPast

    public init(directory: URL) {
        // The previous cache contains misses caused by requiring a song match
        // for album art. Don't preserve those misses after upgrading.
        cacheURL = directory.appendingPathComponent("catalog-v2.json")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 10
        session = URLSession(configuration: configuration)
        if let data = try? Data(contentsOf: cacheURL), let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = saved.filter { $0.value.expiresAt > Date() }
        }
    }
    public func resolve(_ track: Track, country: String) async throws -> TrackExtras? {
        let country = country.uppercased()
        let key = country + "|" + track.identity
        if let entry = entries[key], entry.expiresAt > Date() { return entry.extras }
        let songs = try await search(term: "\(track.title) \(track.artist) \(track.album)", entity: "song", country: country)
        let match = CatalogMatcher.bestMatch(for: track, results: songs)
        var extras = match.map {
            TrackExtras(artworkURL: $0.artworkUrl100.map(Self.largeArtwork), trackURL: $0.trackViewUrl, artistURL: $0.artistViewUrl, albumURL: $0.collectionViewUrl)
        }
        if extras?.artworkURL == nil {
            let albums = try await search(term: "\(track.artist) \(track.album)", entity: "album", country: country)
            if let album = CatalogMatcher.albumMatch(for: track, results: albums) {
                if extras == nil { extras = TrackExtras() }
                extras?.artworkURL = album.artworkUrl100.map(Self.largeArtwork)
                extras?.albumURL = album.collectionViewUrl
                // Never manufacture a song link from an album-only match.
            }
        }
        try Task.checkCancellation()
        entries[key] = Entry(extras: extras, expiresAt: Date().addingTimeInterval(extras == nil ? 3600 : 7 * 86400))
        entries = entries.filter { $0.value.expiresAt > Date() }
        if entries.count > 400 { entries = Dictionary(uniqueKeysWithValues: entries.sorted { $0.value.expiresAt > $1.value.expiresAt }.prefix(300).map { ($0.key, $0.value) }) }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let encoded = try? JSONEncoder().encode(entries) { try? encoded.write(to: cacheURL, options: .atomic) }
        return extras
    }

    private func search(term: String, entity: String, country: String) async throws -> [CatalogResult] {
        // Canceled lookups don't reserve future slots and delay the current song.
        while Date() < nextRequest { try await Task.sleep(for: .seconds(max(0, nextRequest.timeIntervalSinceNow))) }
        try Task.checkCancellation()
        nextRequest = Date().addingTimeInterval(3.1)
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            .init(name: "term", value: term),
            .init(name: "media", value: "music"), .init(name: "entity", value: entity),
            .init(name: "country", value: country), .init(name: "limit", value: "50")
        ]
        let (data, response) = try await session.data(from: components.url!)
        try Task.checkCancellation()
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(Response.self, from: data).results
    }
    private static func largeArtwork(_ url: URL) -> URL {
        guard url.host?.hasSuffix("mzstatic.com") == true else { return url }
        return URL(string: url.absoluteString.replacingOccurrences(of: "100x100bb", with: "600x600bb")) ?? url
    }
}
