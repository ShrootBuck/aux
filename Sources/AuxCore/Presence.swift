import Foundation

public struct TrackExtras: Codable, Equatable, Sendable {
    public var artworkURL: URL?
    public var trackURL: URL?
    public var artistURL: URL?
    public var albumURL: URL?
    public init(artworkURL: URL? = nil, trackURL: URL? = nil, artistURL: URL? = nil, albumURL: URL? = nil) {
        self.artworkURL = artworkURL; self.trackURL = trackURL; self.artistURL = artistURL; self.albumURL = albumURL
    }
}

public struct PresencePayload: Codable, Equatable, Sendable {
    public struct Timestamps: Codable, Equatable, Sendable { public var start: Int64; public var end: Int64 }
    public struct Assets: Codable, Equatable, Sendable { public var large_image: String?; public var large_text: String?; public var large_url: String? }
    public struct Button: Codable, Equatable, Sendable { public var label: String; public var url: String }
    public var type = 2
    public var status_display_type: Int
    public var details: String
    public var state: String?
    public var details_url: String?
    public var state_url: String?
    public var timestamps: Timestamps?
    public var assets: Assets?
    public var buttons: [Button]?

    public static func make(snapshot: PlaybackSnapshot, pausedAt: Date?, extras: TrackExtras?, options: PresenceOptions, now: Date = Date()) -> Self? {
        guard options.enabled, let track = snapshot.track, !track.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        switch snapshot.state {
        case .playing: break
        case .paused:
            guard options.pauseBehavior == .fiveMinutes, let pausedAt, now.timeIntervalSince(pausedAt) < 300 else { return nil }
        case .notRunning, .stopped: return nil
        }
        let isPaused = snapshot.state == .paused
        let state = [track.artist, options.showAlbum ? track.album : ""].filter { !$0.isEmpty }.joined(separator: " · ")
        var payload = Self(status_display_type: options.headline.displayType, details: safeText(track.title), state: state.isEmpty ? nil : safeText(isPaused ? "Paused · \(state)" : state))
        if !isPaused, track.duration > 0 {
            let start = snapshot.sampledAt.timeIntervalSince1970 - min(snapshot.position, track.duration)
            payload.timestamps = .init(start: Int64(start.rounded(.down)), end: Int64((start + track.duration).rounded(.down)))
        }
        if isPaused && state.isEmpty { payload.state = "Paused" }
        if let extras {
            payload.details_url = appleURL(extras.trackURL)
            payload.state_url = appleURL(extras.artistURL)
            if let image = extras.artworkURL, image.scheme == "https" {
                payload.assets = .init(large_image: image.absoluteString, large_text: track.album.isEmpty ? nil : safeText(track.album), large_url: appleURL(extras.albumURL))
            }
            if let url = appleURL(extras.trackURL) { payload.buttons = [.init(label: "Listen on Apple Music", url: url)] }
        }
        return payload
    }

    /// Keep whole graphemes and fit within a conservative UTF-8 byte limit.
    public static func safeText(_ text: String, maxBytes: Int = 128) -> String {
        let clean = text.components(separatedBy: .controlCharacters).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        var result = ""
        if clean.utf8.count > maxBytes {
            for character in clean {
                if result.utf8.count + String(character).utf8.count > maxBytes - 3 { break }
                result.append(character)
            }
            result += "..."
        } else { result = clean }
        while result.count < 2 { result += " " }
        return result
    }
    private static func appleURL(_ url: URL?) -> String? {
        guard let url, url.scheme == "https", let host = url.host,
              host == "music.apple.com" || host == "itunes.apple.com", url.absoluteString.count <= 512 else { return nil }
        return url.absoluteString
    }
}

/// Latest-value publishing: do not queue every transient skip.
public struct PublicationBudget: Sendable {
    private var sent: [Date] = []
    public init() {}
    public mutating func delay(at now: Date, clearing: Bool = false) -> TimeInterval {
        sent.removeAll { now.timeIntervalSince($0) >= 20 }
        let burst = sent.count >= 5 ? max(0, 20 - now.timeIntervalSince(sent[0])) : 0
        let spacing = !clearing && !sent.isEmpty ? max(0, 2 - now.timeIntervalSince(sent.last!)) : 0
        return max(burst, spacing)
    }
    public mutating func record(at now: Date) { sent.append(now) }
}
