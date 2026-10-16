import Testing
import Foundation
import Darwin
@testable import AuxCore

/// A local IPC peer, so these tests inspect actual frames without using Discord.
private final class DiscordPeer: @unchecked Sendable {
    private let lock = NSLock()
    private var connections = 0
    private var closures = 0
    private var frames: [RPCFrame] = []

    var recorded: (connections: Int, closures: Int, frames: [RPCFrame]) {
        lock.lock(); defer { lock.unlock() }
        return (connections, closures, frames)
    }

    func connect() throws -> DiscordSocket {
        var descriptors: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else { throw RPCError.system(errno) }
        let client = DiscordSocket(descriptor: descriptors[0])
        let server = DiscordSocket(descriptor: descriptors[1])
        lock.lock(); connections += 1; lock.unlock()
        DispatchQueue.global().async { [self] in
            defer {
                server.close()
                lock.lock(); closures += 1; lock.unlock()
            }
            do {
                while true {
                    // Wait independently of DiscordSocket's short command
                    // timeout while the publisher is observing its rate limit.
                    var item = pollfd(fd: server.descriptor, events: Int16(POLLIN), revents: 0)
                    guard poll(&item, 1, 10_000) > 0 else { throw RPCError.timedOut }
                    let deadline = Date().addingTimeInterval(2)
                    let frame = try server.read(until: deadline)
                    lock.lock(); frames.append(frame); lock.unlock()
                    if frame.opcode == 0 {
                        try server.sendJSON(opcode: 1, object: ["evt": "READY", "data": ["user": ["username": "test"]]], until: deadline)
                    } else {
                        guard frame.opcode == 1,
                              let command = try JSONSerialization.jsonObject(with: frame.payload) as? [String: Any],
                              let nonce = command["nonce"] as? String else { throw RPCError.invalidFrame }
                        try server.sendJSON(opcode: 1, object: ["cmd": "SET_ACTIVITY", "nonce": nonce, "data": NSNull()], until: deadline)
                    }
                }
            } catch { /* Closing the client ends the session. */ }
        }
        return client
    }

    func waitForClosure(_ count: Int) async throws -> Bool {
        for _ in 0..<100 {
            if recorded.closures >= count { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    func activities() throws -> [Any] {
        try recorded.frames.filter { $0.opcode == 1 }.map {
            let command = try #require(JSONSerialization.jsonObject(with: $0.payload) as? [String: Any])
            #expect(command["cmd"] as? String == "SET_ACTIVITY")
            let args = try #require(command["args"] as? [String: Any])
            return try #require(args["activity"])
        }
    }
}

struct DiscordPublisherTests {
    private let applicationID = "1560471305843646565"
    private let track = Track(id: "one", title: "Smug", artist: "Phoqus", album: "", duration: 224)

    private func payload(at date: Date = Date()) throws -> PresencePayload {
        try #require(PresencePayload.make(snapshot: .init(state: .playing, track: track, position: 30, sampledAt: date), extras: nil, options: .init()))
    }

    @Test func pauseClosesTheSocketWithoutAClearAndStaysDisconnected() async throws {
        let peer = DiscordPeer()
        let publisher = DiscordPublisher(connect: { try peer.connect() })
        let activity = try payload()
        let playing = await publisher.reconcile(activity, applicationID: applicationID, revision: 1)
        #expect(playing.accepted == activity)

        let paused = await publisher.reconcile(nil, applicationID: applicationID, revision: 2, paused: true)
        #expect(paused.connection == .paused)
        #expect(paused.accepted == nil)
        #expect(!paused.pending)
        #expect(try await peer.waitForClosure(1))
        #expect(peer.recorded.frames.map(\.opcode) == [0, 1])

        // Polling, artwork completions, and retry requests all use reconcile.
        for revision in UInt64(3)...7 {
            await publisher.retry()
            let status = await publisher.reconcile(nil, applicationID: applicationID, revision: revision, paused: true)
            #expect(status.connection == .paused)
        }
        let stale = await publisher.reconcile(activity, applicationID: applicationID, revision: 1)
        #expect(stale.connection == .paused)
        // Sleep/quit after a pause must not send a delayed clear either.
        await publisher.disconnect(clear: true, revision: 8)
        #expect(peer.recorded.connections == 1)
        #expect(peer.recorded.frames.map(\.opcode) == [0, 1])
    }

    @Test func pausedStartupDoesNotConnectAndResumePublishesFreshTimestamps() async throws {
        let peer = DiscordPeer()
        let publisher = DiscordPublisher(connect: { try peer.connect() })
        _ = await publisher.reconcile(nil, applicationID: applicationID, revision: 1, paused: true)
        #expect(peer.recorded.connections == 0)

        let first = try payload()
        let playing = await publisher.reconcile(first, applicationID: applicationID, revision: 2)
        #expect(playing.accepted == first)
        _ = await publisher.reconcile(nil, applicationID: applicationID, revision: 3, paused: true)
        #expect(try await peer.waitForClosure(1))

        let resumed = try payload(at: Date().addingTimeInterval(30))
        var status = await publisher.reconcile(resumed, applicationID: applicationID, revision: 4)
        #expect(status.connection == .connected)
        // A rapid resume still honors the normal two-second publication budget.
        let deadline = Date().addingTimeInterval(4)
        while status.pending && Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
            status = await publisher.reconcile(resumed, applicationID: applicationID, revision: 4)
        }
        #expect(status.accepted == resumed)
        #expect(status.accepted?.timestamps != first.timestamps)
        let stalePause = await publisher.reconcile(nil, applicationID: applicationID, revision: 3, paused: true)
        #expect(stalePause.connection == .connected)
        #expect(stalePause.accepted == resumed)
        #expect(peer.recorded.connections == 2)
        let activities = try peer.activities()
        #expect(activities.count == 2)
        #expect(activities.allSatisfy { $0 is [String: Any] })
        await publisher.disconnect(clear: false, revision: 5)
        #expect(try await peer.waitForClosure(2))
    }

    @Test func explicitlyTurningSharingOffCanStillClearAfterAPause() async throws {
        let peer = DiscordPeer()
        let publisher = DiscordPublisher(connect: { try peer.connect() })
        _ = await publisher.reconcile(try payload(), applicationID: applicationID, revision: 1)
        _ = await publisher.reconcile(nil, applicationID: applicationID, revision: 2, paused: true)
        #expect(try await peer.waitForClosure(1))

        let disabled = await publisher.reconcile(nil, applicationID: applicationID, revision: 3)
        #expect(disabled.connection == .connected)
        #expect(!disabled.pending)
        #expect(disabled.accepted == nil)
        let activities = try peer.activities()
        #expect(activities.count == 2)
        #expect(activities.last is NSNull)
        await publisher.disconnect(clear: true, revision: 4)
        #expect(try await peer.waitForClosure(2))
    }
}
