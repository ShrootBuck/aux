import Foundation

public enum PlaybackState: String, Codable, Sendable {
    case notRunning, stopped, paused, playing
}

public struct Track: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var artist: String
    public var album: String
    public var duration: TimeInterval

    public init(id: String, title: String, artist: String, album: String, duration: TimeInterval) {
        self.id = id; self.title = title; self.artist = artist; self.album = album
        self.duration = duration.isFinite ? max(0, duration) : 0
    }
    // Library edits and reused/absent stream IDs must invalidate artwork.
    public var identity: String { [id, title, artist, album, String(Int(duration))].joined(separator: "\u{1f}") }
}

public struct PlaybackSnapshot: Equatable, Sendable {
    public var state: PlaybackState
    public var track: Track?
    public var position: TimeInterval
    public var sampledAt: Date

    public init(state: PlaybackState, track: Track? = nil, position: TimeInterval = 0, sampledAt: Date = Date()) {
        self.state = state; self.track = track
        self.position = position.isFinite ? max(0, position) : 0
        self.sampledAt = sampledAt
    }
    public func position(at date: Date) -> TimeInterval {
        let elapsed = state == .playing ? max(0, date.timeIntervalSince(sampledAt)) : 0
        let value = max(0, position + elapsed)
        return (track?.duration ?? 0) > 0 ? min(value, track!.duration) : value
    }
}

/// Retain the anchor on ordinary polls; reset on seeking, repeat, or a state change.
public struct PlaybackTimeline: Sendable {
    public private(set) var snapshot = PlaybackSnapshot(state: .notRunning)
    public private(set) var pausedAt: Date?
    public init() {}
    @discardableResult
    public mutating func accept(_ incoming: PlaybackSnapshot, force: Bool = false) -> PlaybackSnapshot {
        let sameTrack = snapshot.track?.identity == incoming.track?.identity
        if incoming.state == .paused {
            if snapshot.state != .paused || !sameTrack { pausedAt = incoming.sampledAt }
        } else { pausedAt = nil }
        if !force, sameTrack, incoming.state == .playing, snapshot.state == .playing,
           abs(snapshot.position(at: incoming.sampledAt) - incoming.position) < 1.5 { return snapshot }
        snapshot = incoming
        return snapshot
    }
}

public enum PauseBehavior: String, CaseIterable, Sendable {
    case hide, fiveMinutes
    public var label: String { self == .hide ? "Hide immediately" : "Keep for 5 minutes" }
}

public enum PresenceHeadline: String, CaseIterable, Sendable {
    case song, artist, application
    public var label: String {
        switch self { case .song: return "Song name"; case .artist: return "Artist"; case .application: return "App name" }
    }
    public var displayType: Int {
        switch self { case .song: return 2; case .artist: return 1; case .application: return 0 }
    }
}

public struct PresenceOptions: Sendable {
    public var enabled: Bool
    public var pauseBehavior: PauseBehavior
    public var headline: PresenceHeadline
    public var showAlbum: Bool
    public init(enabled: Bool = true, pauseBehavior: PauseBehavior = .hide, headline: PresenceHeadline = .song, showAlbum: Bool = true) {
        self.enabled = enabled; self.pauseBehavior = pauseBehavior; self.headline = headline; self.showAlbum = showAlbum
    }
}
