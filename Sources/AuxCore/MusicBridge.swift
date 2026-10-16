import AppKit
import Foundation

private func fourCC(_ string: String) -> OSType { string.utf8.reduce(0) { ($0 << 8) | OSType($1) } }

public enum MusicError: LocalizedError {
    case permissionDenied, notRunning, trackChanged, event(Int, String)
    public var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Allow Aux to access Music in System Settings → Privacy & Security → Automation."
        case .notRunning: return "Apple Music isn't open."
        case .trackChanged: return "The track changed while reading it."
        case .event(let code, let message): return "Music: \(message) (\(code))"
        }
    }
}

/// Native Apple events, serialized off the UI thread. No shell, polling subprocess,
/// System Events permission, or private MediaRemote framework.
public actor MusicBridge {
    private var cachedTrack: Track?
    private var metadataReadAt = Date.distantPast
    public init() {}

    private func target() throws -> NSAppleEventDescriptor {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").first else { throw MusicError.notRunning }
        // Address the existing PID so a stale polling tick cannot launch Music.
        return NSAppleEventDescriptor(processIdentifier: app.processIdentifier)
    }

    private func property(_ name: String, of container: NSAppleEventDescriptor? = nil) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: fourCC("prop")), forKeyword: fourCC("want"))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: fourCC("prop")), forKeyword: fourCC("form"))
        record.setDescriptor(NSAppleEventDescriptor(typeCode: fourCC(name)), forKeyword: fourCC("seld"))
        record.setDescriptor(container ?? .null(), forKeyword: fourCC("from"))
        return record.coerce(toDescriptorType: fourCC("obj "))!
    }

    private func send(eventClass: String = "core", id: String, direct: NSAppleEventDescriptor? = nil, value: NSAppleEventDescriptor? = nil) throws -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: fourCC(eventClass), eventID: fourCC(id), targetDescriptor: try target(), returnID: -1, transactionID: 0)
        if let direct { event.setParam(direct, forKeyword: fourCC("----")) }
        if let value { event.setParam(value, forKeyword: fourCC("data")) }
        do {
            let reply = try event.sendEvent(options: [.waitForReply, .canInteract], timeout: 2)
            let error = Int(reply.paramDescriptor(forKeyword: fourCC("errn"))?.int32Value ?? 0)
            if error == -1743 { throw MusicError.permissionDenied }
            if error != 0 { throw MusicError.event(error, reply.paramDescriptor(forKeyword: fourCC("errs"))?.stringValue ?? "Apple event failed") }
            return reply.paramDescriptor(forKeyword: fourCC("----")) ?? .null()
        } catch let error as NSError where error.code == -1743 { throw MusicError.permissionDenied }
    }

    private func get(_ propertyCode: String, of container: NSAppleEventDescriptor? = nil) throws -> NSAppleEventDescriptor {
        try send(id: "getd", direct: property(propertyCode, of: container))
    }

    public func snapshot() throws -> PlaybackSnapshot {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty else {
            cachedTrack = nil
            return .init(state: .notRunning)
        }
        let playerState = try get("pPlS").enumCodeValue
        let state: PlaybackState
        switch playerState {
        case fourCC("kPSP"), fourCC("kPSF"), fourCC("kPSR"): state = .playing
        case fourCC("kPSp"): state = .paused
        default: state = .stopped
        }
        guard state != .stopped else { cachedTrack = nil; return .init(state: .stopped) }
        let trackRef = try get("pTrk")
        let id = (try? get("pPIS", of: trackRef).stringValue) ?? ""
        if cachedTrack?.id != id || cachedTrack == nil || Date().timeIntervalSince(metadataReadAt) > 15 || id.isEmpty {
            let name = try get("pnam", of: trackRef).stringValue ?? ""
            let artist = try get("pArt", of: trackRef).stringValue ?? ""
            let album = try get("pAlb", of: trackRef).stringValue ?? ""
            let duration = (try? get("pDur", of: trackRef).doubleValue) ?? 0
            cachedTrack = Track(id: id, title: name, artist: artist, album: album, duration: duration)
            metadataReadAt = Date()
        }
        let position = try get("pPos").doubleValue
        // Don't publish metadata from one track with the next track's position.
        let currentID = (try? get("pPIS", of: property("pTrk")).stringValue) ?? ""
        guard currentID == id else { cachedTrack = nil; throw MusicError.trackChanged }
        return .init(state: state, track: cachedTrack, position: position)
    }

    public func artwork(for track: Track) throws -> Data? {
        let trackRef = try get("pTrk")
        let id = (try? get("pPIS", of: trackRef).stringValue) ?? ""
        let name = try get("pnam", of: trackRef).stringValue ?? ""
        guard id == track.id, name == track.title else { throw MusicError.trackChanged }
        let artwork = NSAppleEventDescriptor.record()
        artwork.setDescriptor(NSAppleEventDescriptor(typeCode: fourCC("cArt")), forKeyword: fourCC("want"))
        artwork.setDescriptor(NSAppleEventDescriptor(enumCode: fourCC("indx")), forKeyword: fourCC("form"))
        artwork.setDescriptor(NSAppleEventDescriptor(int32: 1), forKeyword: fourCC("seld"))
        artwork.setDescriptor(trackRef, forKeyword: fourCC("from"))
        let ref = artwork.coerce(toDescriptorType: fourCC("obj "))!
        guard let value = try? get("pRaw", of: ref), value.descriptorType != fourCC("null") else { return nil }
        let data = value.data
        return data.isEmpty || data.count > 20_000_000 ? nil : data
    }

    public enum Command: Sendable { case playPause, next, previous, seek(TimeInterval) }
    public func perform(_ command: Command) throws {
        switch command {
        case .playPause: _ = try send(eventClass: "hook", id: "PlPs")
        case .next: _ = try send(eventClass: "hook", id: "Next")
        case .previous: _ = try send(eventClass: "hook", id: "Back")
        case .seek(let position):
            guard position.isFinite else { return }
            _ = try send(id: "setd", direct: property("pPos"), value: NSAppleEventDescriptor(double: max(0, position)))
        }
        metadataReadAt = .distantPast
    }
}
