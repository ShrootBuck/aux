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
    private let responseData: @Sendable ([String: Any]) -> [String: Any]?

    init(responseData: @escaping @Sendable ([String: Any]) -> [String: Any]? = { _ in nil }) {
        self.responseData = responseData
    }

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
        // The publisher blocks while waiting for this peer. A dedicated thread
        // keeps the reply independent of the test executor's worker pool.
        Thread.detachNewThread { [self] in
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
                        let data: Any = responseData(command).map { $0 as Any } ?? NSNull()
                        try server.sendJSON(opcode: 1, object: ["cmd": "SET_ACTIVITY", "nonce": nonce, "data": data], until: deadline)
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

    private let libraryURL = URL(string: "https://files.catbox.moe/library.jpg")!
    private let catalogURL = URL(string: "https://is1-ssl.mzstatic.com/catalog.jpg")!

    private func artworkPayload() throws -> PresencePayload {
        try #require(PresencePayload.make(snapshot: .init(state: .playing, track: track, position: 30),
                                         extras: .init(artworkURL: libraryURL, trackURL: URL(string: "https://music.apple.com/us/song/123")), options: .init()))
    }

    private func artworkPeer() -> DiscordPeer {
        DiscordPeer { command in
            guard let args = command["args"] as? [String: Any], var activity = args["activity"] as? [String: Any] else { return nil }
            if var assets = activity["assets"] as? [String: Any], let url = assets["large_image"] as? String {
                assets["large_image"] = "mp:external/test/https/" + url.dropFirst("https://".count)
                activity["assets"] = assets
            }
            return activity
        }
    }

    private func settle(_ publisher: DiscordPublisher, _ activity: PresencePayload, fallback: URL?, expectedImage: String?) async throws -> PublicationStatus {
        let deadline = Date().addingTimeInterval(7)
        var status = PublicationStatus()
        repeat {
            status = await publisher.reconcile(activity, applicationID: applicationID, revision: 2, fallbackArtworkURL: fallback)
            if !status.pending, status.accepted?.assets?.large_image == expectedImage,
               status.artwork == .available || status.artwork == .unavailable { return status }
            try await Task.sleep(for: .milliseconds(20))
        } while Date() < deadline
        Issue.record("Artwork did not settle: \(status)")
        return status
    }

    @Test func acceptedButBrokenProxyFallsBackAndKeepsSongDetails() async throws {
        let peer = artworkPeer()
        let publisher = DiscordPublisher(connect: { try peer.connect() }, verifyArtwork: { reference in
            #expect(reference?.hasPrefix("mp:external/") == true)
            return reference?.contains("mzstatic.com") == true
        })
        let activity = try artworkPayload()
        let initial = await publisher.reconcile(activity, applicationID: applicationID, revision: 1, fallbackArtworkURL: catalogURL)
        #expect(initial.accepted == activity) // Accepted RPC is not image success.
        #expect(initial.artwork == .checking)
        let status = try await settle(publisher, activity, fallback: catalogURL, expectedImage: catalogURL.absoluteString)
        #expect(status.artwork == .available)
        #expect(status.artworkMessage?.contains("using Apple catalog") == true)
        #expect(status.failedArtworkURL == libraryURL)
        #expect(status.accepted?.details == activity.details)
        #expect(status.accepted?.timestamps == activity.timestamps)
        #expect(status.accepted?.buttons == activity.buttons)
        // Repeated polls must not republish the bad URL or retry an upload.
        for revision in UInt64(3)...10 {
            _ = await publisher.reconcile(activity, applicationID: applicationID, revision: revision, fallbackArtworkURL: catalogURL)
        }
        #expect(try peer.activities().count == 2)
        await publisher.disconnect(clear: false)
    }

    @Test func healthyLibraryImageIsKeptInsteadOfCatalogFallback() async throws {
        let peer = artworkPeer()
        let publisher = DiscordPublisher(connect: { try peer.connect() }, verifyArtwork: { _ in true })
        let activity = try artworkPayload()
        let status = try await settle(publisher, activity, fallback: catalogURL, expectedImage: libraryURL.absoluteString)
        #expect(status.artwork == .available)
        #expect(status.artworkMessage == nil)
        #expect(status.failedArtworkURL == nil)
        #expect(status.accepted == activity)
        #expect(try peer.activities().count == 1)
        await publisher.disconnect(clear: false)
    }

    @Test func bothBrokenImagesAreRemovedWithoutClearingSong() async throws {
        let peer = artworkPeer()
        let publisher = DiscordPublisher(connect: { try peer.connect() }, verifyArtwork: { _ in false })
        let activity = try artworkPayload()
        let status = try await settle(publisher, activity, fallback: catalogURL, expectedImage: nil)
        #expect(status.artwork == .unavailable)
        #expect(status.accepted?.details == activity.details)
        #expect(status.accepted?.assets == nil)
        #expect(status.artworkMessage == "Artwork unavailable in Discord · will retry")
        #expect(try peer.activities().count == 3)
        await publisher.disconnect(clear: false)
    }

    @Test func missingImageInAcknowledgementDoesNotCountAsSuccess() async throws {
        let peer = DiscordPeer()
        let publisher = DiscordPublisher(connect: { try peer.connect() }, verifyArtwork: { reference in
            #expect(reference == nil)
            return ArtworkService.discordProxyURL(reference) != nil
        })
        let activity = try artworkPayload()
        let status = try await settle(publisher, activity, fallback: nil, expectedImage: nil)
        #expect(status.artwork == .unavailable)
        #expect(status.accepted?.details == activity.details)
        await publisher.disconnect(clear: false)
    }

    @Test func slowImageVerificationDoesNotBlockPauseOrReviveOldActivity() async throws {
        let peer = artworkPeer()
        let publisher = DiscordPublisher(connect: { try peer.connect() }, verifyArtwork: { _ in
            try? await Task.sleep(for: .seconds(30))
            return false
        })
        let activity = try artworkPayload()
        _ = await publisher.reconcile(activity, applicationID: applicationID, revision: 1)
        let started = Date()
        let paused = await publisher.reconcile(nil, applicationID: applicationID, revision: 2, paused: true)
        #expect(Date().timeIntervalSince(started) < 1)
        #expect(paused.connection == .paused)
        #expect(paused.artwork == .none)
        #expect(try await peer.waitForClosure(1))
        let status = await publisher.reconcile(nil, applicationID: applicationID, revision: 3, paused: true)
        #expect(status.accepted == nil)
        #expect(status.artwork == .none)
        #expect(try peer.activities().count == 1)
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
