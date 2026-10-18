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
    /// Unix milliseconds, preserving the playback clock's fractional second.
    public struct Timestamps: Codable, Equatable, Sendable { public var start: Int64; public var end: Int64 }
    public struct Assets: Codable, Equatable, Sendable { public var large_image: String?; public var large_text: String?; public var large_url: String? }
    public struct Button: Codable, Equatable, Sendable { public var label: String; public var url: String }
    public var name = "Apple Music"
    public var type = 2
    public var status_display_type: Int
    public var details: String
    public var state: String?
    public var details_url: String?
    public var state_url: String?
    public var timestamps: Timestamps?
    public var assets: Assets?
    public var buttons: [Button]?

    public static func make(snapshot: PlaybackSnapshot, extras: TrackExtras?, options: PresenceOptions) -> Self? {
        guard options.enabled, snapshot.state == .playing, let track = snapshot.track,
              !track.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var payload = Self(status_display_type: options.headline.displayType, details: safeText(track.title), state: track.artist.isEmpty ? nil : safeText(track.artist))
        if track.duration > 0 {
            let start = snapshot.playbackStartedAt.timeIntervalSince1970
            payload.timestamps = .init(start: Int64((start * 1000).rounded()), end: Int64(((start + track.duration) * 1000).rounded()))
        }
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
    public mutating func delay(at now: Date) -> TimeInterval {
        sent.removeAll { now.timeIntervalSince($0) >= 20 }
        let burst = sent.count >= 5 ? max(0, 20 - now.timeIntervalSince(sent[0])) : 0
        let spacing = !sent.isEmpty ? max(0, 2 - now.timeIntervalSince(sent.last!)) : 0
        return max(burst, spacing)
    }
    public mutating func record(at now: Date) { sent.append(now) }
}
