import Foundation
import Darwin

public enum RPCError: LocalizedError {
    case unavailable, disconnected, timedOut, invalidFrame, rejected(String), system(Int32)
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "Open Discord on this Mac to connect."
        case .disconnected: return "Discord disconnected. Aux will reconnect."
        case .timedOut: return "Discord didn't respond. Aux will retry."
        case .invalidFrame: return "Discord sent an invalid response."
        case .rejected(let reason): return reason
        case .system(let code): return String(cString: strerror(code))
        }
    }
}

public struct RPCFrame: Equatable, Sendable {
    public let opcode: UInt32
    public let payload: Data
    public init(opcode: UInt32, payload: Data) { self.opcode = opcode; self.payload = payload }
    public func encoded() -> Data {
        var op = opcode.littleEndian, length = UInt32(payload.count).littleEndian
        var result = withUnsafeBytes(of: &op) { Data($0) }
        result.append(withUnsafeBytes(of: &length) { Data($0) })
        result.append(payload)
        return result
    }
    public static func header(_ data: Data) throws -> (opcode: UInt32, length: Int) {
        guard data.count == 8 else { throw RPCError.invalidFrame }
        let bytes = Array(data)
        func word(_ index: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(bytes[index + $1]) << (8 * $1) } }
        let size = Int(word(4))
        guard size <= 1_048_576 else { throw RPCError.invalidFrame }
        return (word(0), size)
    }
}

/// All socket work is performed inside DiscordPublisher's actor, with bounded
/// poll/read/write operations. Pending commands can't survive a disconnect.
final class DiscordSocket {
    private(set) var descriptor: Int32
    init(descriptor: Int32) {
        self.descriptor = descriptor
        var one: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
    }
    deinit { close() }
    func close() { if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 } }

    static func connect(paths: [String]? = nil) throws -> DiscordSocket {
        let env = ProcessInfo.processInfo.environment
        let roots = [env["XDG_RUNTIME_DIR"], env["TMPDIR"], env["TMP"], env["TEMP"], "/tmp"].compactMap { $0 }
        let paths = paths ?? Array(NSOrderedSet(array: roots).array as? [String] ?? roots).flatMap { root in
            (0..<10).map { URL(fileURLWithPath: root).appendingPathComponent("discord-ipc-\($0)").path }
        }
        for path in paths {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            var address = sockaddr_un()
            let bytes = Array(path.utf8) + [0]
            guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { continue }
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { continue }
            let connection = DiscordSocket(descriptor: fd)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            if result == 0 { return connection }
            if errno == EINPROGRESS {
                do {
                    try connection.ready(POLLOUT, until: Date().addingTimeInterval(0.3))
                    var socketError: Int32 = 0
                    var size = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &size)
                    if socketError == 0 { return connection }
                } catch {}
            }
            connection.close()
        }
        throw RPCError.unavailable
    }

    private func ready(_ events: Int32, until deadline: Date) throws {
        guard descriptor >= 0 else { throw RPCError.disconnected }
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw RPCError.timedOut }
            var descriptor = pollfd(fd: descriptor, events: Int16(events), revents: 0)
            let result = poll(&descriptor, 1, Int32(max(1, min(remaining * 1000, 2_000))))
            if result < 0 { if errno == EINTR { continue }; throw RPCError.system(errno) }
            if result == 0 { throw RPCError.timedOut }
            if Int32(descriptor.revents) & events != 0 { return }
            if Int32(descriptor.revents) & (POLLHUP | POLLERR | POLLNVAL) != 0 { throw RPCError.disconnected }
        }
    }
    private func readExactly(_ size: Int, until deadline: Date) throws -> Data {
        var result = Data(count: size)
        var offset = 0
        while offset < size {
            try ready(POLLIN, until: deadline)
            let count = result.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!.advanced(by: offset), size - offset) }
            if count == 0 { throw RPCError.disconnected }
            if count < 0 { if errno == EINTR || errno == EAGAIN { continue }; throw RPCError.system(errno) }
            offset += count
        }
        return result
    }
    func write(_ frame: RPCFrame, until deadline: Date) throws {
        let data = frame.encoded()
        var offset = 0
        while offset < data.count {
            try ready(POLLOUT, until: deadline)
            let count = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            if count <= 0 { if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }; throw RPCError.disconnected }
            offset += count
        }
    }
    func read(until deadline: Date) throws -> RPCFrame {
        let header = try RPCFrame.header(readExactly(8, until: deadline))
        return RPCFrame(opcode: header.opcode, payload: try readExactly(header.length, until: deadline))
    }
    func sendJSON(opcode: UInt32, object: [String: Any], until deadline: Date) throws {
        try write(.init(opcode: opcode, payload: JSONSerialization.data(withJSONObject: object)), until: deadline)
    }
    func response(nonce: String? = nil, until deadline: Date) throws -> [String: Any] {
        while true {
            let frame = try read(until: deadline)
            if frame.opcode == 3 { try write(.init(opcode: 4, payload: frame.payload), until: deadline); continue }
            if frame.opcode == 2 { throw RPCError.disconnected }
            guard frame.opcode == 1, let object = try JSONSerialization.jsonObject(with: frame.payload) as? [String: Any] else { throw RPCError.invalidFrame }
            if object["evt"] as? String == "ERROR" {
                let message = (object["data"] as? [String: Any])?["message"] as? String ?? "Discord rejected the activity."
                throw RPCError.rejected(message)
            }
            if let nonce { if object["nonce"] as? String == nonce { return object } }
            else if object["evt"] as? String == "READY" { return object }
        }
    }
    func maintain() throws {
        var item = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let result = poll(&item, 1, 0)
        if result < 0 { throw RPCError.system(errno) }
        if Int32(item.revents) & (POLLHUP | POLLERR | POLLNVAL) != 0 { throw RPCError.disconnected }
        if Int32(item.revents) & POLLIN != 0 {
            let deadline = Date().addingTimeInterval(1)
            let frame = try read(until: deadline)
            if frame.opcode == 2 { throw RPCError.disconnected }
            if frame.opcode == 3 { try write(.init(opcode: 4, payload: frame.payload), until: deadline) }
        }
    }
}

public struct PublicationStatus: Equatable, Sendable {
    public enum Connection: String, Sendable { case needsSetup, waiting, connected, paused }
    public enum Artwork: String, Sendable { case none, checking, available, unavailable }
    public var connection: Connection = .needsSetup
    public var accepted: PresencePayload?
    public var acceptedAt: Date?
    public var pending = false
    public var message: String?
    public var userName: String?
    public var artwork: Artwork = .none
    public var artworkMessage: String?
    public var failedArtworkURL: URL?
    public init() {}
}

public actor DiscordPublisher {
    private let connect: @Sendable () throws -> DiscordSocket
    private let verifyArtwork: @Sendable (String?) async -> DiscordImageResult
    private struct ImageCheck {
        var available: Bool
        var expires: Date
        var failure: String?
    }
    private var imageChecks: [String: ImageCheck] = [:]
    private var imageFailures: [String: Int] = [:]
    private var imageVerification: Task<Void, Never>?
    private var imageVerificationID: UUID?
    private var verifyingImage: String?
    private var acceptedImageReference: String?
    private var socket: DiscordSocket?
    private var applicationID = ""
    private var latestRevision: UInt64 = 0
    private var nextConnection = Date.distantPast
    private var failures = 0
    private var hasAcknowledgedState = false
    private var budget = PublicationBudget()
    private var status = PublicationStatus()
    public init() {
        connect = { try DiscordSocket.connect() }
        let images = ArtworkService()
        verifyArtwork = { await images.checkDiscordImage($0) }
    }
    init(connect: @escaping @Sendable () throws -> DiscordSocket,
         verifyArtwork: @escaping @Sendable (String?) async -> Bool = { _ in false }) {
        self.connect = connect
        self.verifyArtwork = { .init(available: await verifyArtwork($0)) }
    }
    public static func validApplicationID(_ value: String) -> Bool {
        (17...20).contains(value.count) && value.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
    }

    public func reconcile(_ desired: PresencePayload?, applicationID id: String, revision: UInt64, paused: Bool = false, fallbackArtworkURL: URL? = nil) -> PublicationStatus {
        guard revision >= latestRevision else { return status }
        latestRevision = revision
        // Pausing ends the IPC session without sending SET_ACTIVITY(null).
        // Check before maintenance/reconnection so polls, artwork completions,
        // and manual retries cannot reopen the socket while playback is paused.
        if paused {
            disconnect(clear: false)
            status.connection = .paused
            failures = 0
            return status
        }
        if applicationID != id {
            disconnect(clear: true)
            applicationID = id
            nextConnection = .distantPast
            failures = 0
        }
        guard Self.validApplicationID(id) else { status = .init(); return status }
        imageChecks = imageChecks.filter { $0.value.expires > Date() }
        var effective = desired
        status.artworkMessage = nil
        status.failedArtworkURL = nil
        if let image = desired?.assets?.large_image, imageChecks[image]?.available == false {
            status.failedArtworkURL = URL(string: image)
            if let fallback = fallbackArtworkURL, fallback.scheme == "https",
               fallback.absoluteString != image, imageChecks[fallback.absoluteString]?.available != false {
                effective?.assets?.large_image = fallback.absoluteString
                status.artworkMessage = "Preferred artwork unavailable in Discord · using Apple catalog artwork"
            } else {
                effective?.assets = nil
                status.artworkMessage = "Artwork unavailable in Discord · will retry"
                if let failure = imageChecks[image]?.failure { status.artworkMessage = failure + " · will retry" }
            }
        }
        let image = effective?.assets?.large_image
        if verifyingImage != image { cancelImageVerification() }
        status.artwork = image == nil ? (desired?.assets?.large_image == nil ? .none : .unavailable) :
            (imageChecks[image!]?.available == true ? .available : .checking)
        do {
            if let socket { try socket.maintain() }
            if socket == nil {
                status.connection = .waiting
                guard Date() >= nextConnection else { return status }
                let connection = try connect()
                let deadline = Date().addingTimeInterval(2)
                try connection.sendJSON(opcode: 0, object: ["v": 1, "client_id": id], until: deadline)
                let response = try connection.response(until: deadline)
                socket = connection
                hasAcknowledgedState = false
                failures = 0
                status.userName = ((response["data"] as? [String: Any])?["user"] as? [String: Any])?["username"] as? String
                status.connection = .connected
                status.message = nil
            }
            status.pending = !hasAcknowledgedState || effective != status.accepted
            guard status.pending else {
                if let image, imageChecks[image] == nil, verifyingImage != image {
                    checkImage(image, reference: acceptedImageReference)
                }
                return status
            }
            guard budget.delay(at: Date(), clearing: desired == nil) == 0 else { return status }
            let nonce = UUID().uuidString
            let activity: Any = try effective.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) } ?? NSNull()
            let deadline = Date().addingTimeInterval(2)
            try socket!.sendJSON(opcode: 1, object: ["cmd": "SET_ACTIVITY", "args": ["pid": ProcessInfo.processInfo.processIdentifier, "activity": activity], "nonce": nonce], until: deadline)
            budget.record(at: Date())
            let response = try socket!.response(nonce: nonce, until: deadline)
            status.accepted = effective
            hasAcknowledgedState = true
            status.acceptedAt = Date()
            status.pending = false
            status.message = nil
            acceptedImageReference = ((response["data"] as? [String: Any])?["assets"] as? [String: Any])?["large_image"] as? String
            if let image, imageChecks[image] == nil, verifyingImage != image {
                checkImage(image, reference: acceptedImageReference)
            }
        } catch {
            cancelImageVerification()
            socket?.close(); socket = nil
            status.connection = .waiting
            status.accepted = nil
            acceptedImageReference = nil
            status.acceptedAt = nil
            status.pending = desired != nil
            status.message = error.localizedDescription
            failures += 1
            nextConnection = Date().addingTimeInterval(min(30, pow(2, Double(min(failures, 5)))))
        }
        return status
    }

    private func checkImage(_ image: String, reference: String?) {
        cancelImageVerification()
        let token = UUID()
        imageVerificationID = token
        verifyingImage = image
        let verify = verifyArtwork
        // Do not hold up Music polling, pause, or text updates while the CDN is
        // slow. A later reconcile publishes the fallback within the RPC budget.
        imageVerification = Task { [weak self] in
            let result = await verify(reference)
            guard !Task.isCancelled else { return }
            await self?.finishImageCheck(image, result: result, token: token)
        }
    }

    private func finishImageCheck(_ image: String, result: DiscordImageResult, token: UUID) {
        guard imageVerificationID == token else { return }
        let available = result.available
        if imageChecks.count >= 128, let oldest = imageChecks.min(by: { $0.value.expires < $1.value.expires })?.key {
            imageChecks[oldest] = nil
            imageFailures[oldest] = nil
        }
        // A broken proxy must not cause repeated uploads or a request each poll.
        if imageFailures.count >= 128 { imageFailures.removeAll() }
        let failures = available ? 0 : min(4, (imageFailures[image] ?? 0) + 1)
        imageFailures[image] = available ? nil : failures
        let delay: TimeInterval = available ? 3600 : [10.0, 30, 90, 300][failures - 1]
        imageChecks[image] = ImageCheck(available: available, expires: Date().addingTimeInterval(delay), failure: result.failure)
        imageVerification = nil
        imageVerificationID = nil
        verifyingImage = nil
        status.artwork = available ? .available : .unavailable
    }

    private func cancelImageVerification() {
        imageVerification?.cancel()
        imageVerification = nil
        imageVerificationID = nil
        verifyingImage = nil
    }
    public func retry() { nextConnection = .distantPast }
    public func retryArtwork(_ url: URL) {
        imageChecks[url.absoluteString] = nil
        imageFailures[url.absoluteString] = nil
    }
    public func disconnect(clear: Bool, revision: UInt64? = nil) {
        if let revision {
            guard revision >= latestRevision else { return }
            latestRevision = revision
        }
        cancelImageVerification()
        if clear, let socket, status.accepted != nil {
            let nonce = UUID().uuidString
            let deadline = Date().addingTimeInterval(0.5)
            try? socket.sendJSON(opcode: 1, object: ["cmd": "SET_ACTIVITY", "args": ["pid": ProcessInfo.processInfo.processIdentifier, "activity": NSNull()], "nonce": nonce], until: deadline)
            _ = try? socket.response(nonce: nonce, until: deadline)
        }
        socket?.close(); socket = nil
        hasAcknowledgedState = false
        acceptedImageReference = nil
        status = .init()
        nextConnection = .distantPast
    }
}
