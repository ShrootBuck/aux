import Testing
import Foundation
import Darwin
@testable import AuxCore

struct AuxCoreTests {
    let track = Track(id: "one", title: "Everything In Its Right Place", artist: "Radiohead", album: "Kid A", duration: 251)
    let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func testPollingDoesNotContinuouslyResetDiscordTimestamps() {
        var timeline = PlaybackTimeline()
        let first = timeline.accept(.init(state: .playing, track: track, position: 40, sampledAt: epoch))
        let second = timeline.accept(.init(state: .playing, track: track, position: 41.9, sampledAt: epoch.addingTimeInterval(2)))
        #expect(first == second)
    }
    @Test func testSeekRepeatAndWakeResetTimeline() {
        var timeline = PlaybackTimeline()
        _ = timeline.accept(.init(state: .playing, track: track, position: 245, sampledAt: epoch))
        let repeated = timeline.accept(.init(state: .playing, track: track, position: 0, sampledAt: epoch.addingTimeInterval(6)))
        #expect(repeated.position == 0)
        let seek = timeline.accept(.init(state: .playing, track: track, position: 120, sampledAt: epoch.addingTimeInterval(7)))
        #expect(seek.position == 120)
        let wake = timeline.accept(.init(state: .playing, track: track, position: 120.5, sampledAt: epoch.addingTimeInterval(8)), force: true)
        #expect(wake.sampledAt == epoch.addingTimeInterval(8))
    }
    @Test func testPausedPlaybackNeverBuildsAnActivityAndResumeRestoresIt() {
        var timeline = PlaybackTimeline()
        for state in [PlaybackState.playing, .paused, .paused, .playing] {
            let snapshot = timeline.accept(.init(state: state, track: track, position: 30, sampledAt: epoch))
            let payload = PresencePayload.make(snapshot: snapshot, extras: nil, options: .init())
            #expect((payload != nil) == (state == .playing))
        }
    }
    @Test func testAppleMusicNameAndArtistOnlyStatusPreserveAlbumArtwork() throws {
        let extras = TrackExtras(artworkURL: URL(string: "https://is1-ssl.mzstatic.com/cover.jpg"))
        for headline in PresenceHeadline.allCases {
            let payload = try #require(PresencePayload.make(snapshot: .init(state: .playing, track: track), extras: extras, options: .init(headline: headline)))
            #expect(payload.name == "Apple Music")
            #expect(payload.state == "Radiohead")
            #expect(payload.assets?.large_text == "Kid A")
            #expect(payload.status_display_type == headline.displayType)
            let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
            #expect(json["name"] as? String == "Apple Music")
        }
    }
    @Test func testDisabledAndStoppedNeverPublish() {
        let playing = PlaybackSnapshot(state: .playing, track: track, sampledAt: epoch)
        #expect(PresencePayload.make(snapshot: playing, extras: nil, options: .init(enabled: false)) == nil)
        #expect(PresencePayload.make(snapshot: .init(state: .stopped, track: track), extras: nil, options: .init()) == nil)
    }
    @Test func testProgressAndTimestampsAreBoundedAndUseMilliseconds() {
        let snapshot = PlaybackSnapshot(state: .playing, track: track, position: 50, sampledAt: epoch)
        let payload = PresencePayload.make(snapshot: snapshot, extras: nil, options: .init())!
        #expect(payload.timestamps?.start == 1_699_999_950_000)
        #expect(payload.timestamps?.end == 1_700_000_201_000)
        #expect(snapshot.position(at: epoch.addingTimeInterval(500)) == 251)
    }
    @Test func testFractionalPlaybackClockSurvivesDiscordJSONEncoding() throws {
        let fractionalTrack = Track(id: "fractional", title: "Song", artist: "Artist", album: "Album", duration: 251.375)
        let snapshot = PlaybackSnapshot(state: .playing, track: fractionalTrack, position: 48.125,
                                        sampledAt: epoch.addingTimeInterval(0.987))
        let payload = try #require(PresencePayload.make(snapshot: snapshot, extras: nil, options: .init()))
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        let timestamps = try #require(json["timestamps"] as? [String: NSNumber])
        let start = try #require(timestamps["start"]).doubleValue / 1000
        let end = try #require(timestamps["end"]).doubleValue / 1000
        #expect(abs(start - snapshot.playbackStartedAt.timeIntervalSince1970) < 0.001)
        #expect(abs(end - start - fractionalTrack.duration) < 0.001)
        for elapsed in stride(from: 0.0, through: 20, by: 0.1) {
            let date = snapshot.sampledAt.addingTimeInterval(elapsed)
            #expect(abs(date.timeIntervalSince1970 - start - snapshot.position(at: date)) < 0.001)
        }
    }
    @Test func testOrdinaryPollsKeepOneClockThroughIrregularRefreshes() {
        var timeline = PlaybackTimeline()
        let first = timeline.accept(.init(state: .playing, track: track, position: 40.375, sampledAt: epoch))
        let payload = PresencePayload.make(snapshot: first, extras: nil, options: .init())
        for (elapsed, noise) in [(1.5, -0.08), (3.01, 0.12), (4.52, -0.15), (7.2, 0.04)] {
            let accepted = timeline.accept(.init(state: .playing, track: track, position: 40.375 + elapsed + noise,
                                                  sampledAt: epoch.addingTimeInterval(elapsed)))
            #expect(accepted.playbackStartedAt == first.playbackStartedAt)
            #expect(PresencePayload.make(snapshot: accepted, extras: nil, options: .init()) == payload)
            for second in 41...50 {
                let boundary = accepted.playbackStartedAt.addingTimeInterval(Double(second))
                #expect(Int(accepted.position(at: boundary.addingTimeInterval(-0.001))) == second - 1)
                #expect(Int(accepted.position(at: boundary.addingTimeInterval(0.001))) == second)
            }
        }
    }
    @Test func testOneWrongSearchResultIsRejected() {
        let wrong = CatalogResult(trackName: track.title, artistName: "Cover Band", collectionName: track.album, trackTimeMillis: 251000)
        #expect(CatalogMatcher.bestMatch(for: track, results: [wrong]) == nil)
    }
    @Test func testAlbumVersionAndDurationMustMatch() {
        let deluxe = CatalogResult(trackName: track.title, artistName: track.artist, collectionName: "Kid A (Deluxe)", trackTimeMillis: 251000)
        let long = CatalogResult(trackName: track.title, artistName: track.artist, collectionName: track.album, trackTimeMillis: 400000)
        let correct = CatalogResult(trackName: track.title.uppercased(), artistName: track.artist, collectionName: track.album, trackTimeMillis: 251100)
        #expect(CatalogMatcher.bestMatch(for: track, results: [deluxe, long, correct]) == correct)
    }
    @Test func testUnicodeNeverSplitsGraphemesOrExceedsByteLimit() {
        let result = PresencePayload.safeText(String(repeating: "👩🏽‍🚀", count: 20))
        #expect(result.utf8.count <= 128)
        #expect(result.hasSuffix("..."))
        #expect(PresencePayload.safeText("A") == "A ")
    }
    @Test func testRemasterMismatchCanUseAlbumCoverWithoutMatchingRecording() {
        let juicy = Track(id: "juicy", title: "Juicy (2007 Remaster)", artist: "The Notorious B.I.G.", album: "Greatest Hits", duration: 302)
        let result = CatalogResult(trackName: "Juicy", artistName: juicy.artist, collectionName: juicy.album, trackTimeMillis: 285760, artworkUrl100: URL(string: "https://is1-ssl.mzstatic.com/image/600x600bb.jpg"))
        #expect(CatalogMatcher.bestMatch(for: juicy, results: [result]) == nil)
        #expect(CatalogMatcher.albumMatch(for: juicy, results: [result]) == result)
        let extras = TrackExtras(artworkURL: result.artworkUrl100)
        let payload = PresencePayload.make(snapshot: .init(state: .playing, track: juicy), extras: extras, options: .init())
        #expect(payload?.assets?.large_image == result.artworkUrl100?.absoluteString)
        #expect(payload?.details_url == nil)
        #expect(payload?.buttons == nil)
    }
    @Test func testAlbumArtworkRejectsWrongArtistAndEdition() {
        let cover = URL(string: "https://is1-ssl.mzstatic.com/image/600x600bb.jpg")!
        let otherArtist = CatalogResult(trackName: "", artistName: "Cover Band", collectionName: track.album, artworkUrl100: cover)
        let otherEdition = CatalogResult(trackName: "", artistName: track.artist, collectionName: "Kid A (Deluxe)", artworkUrl100: cover)
        let notApple = CatalogResult(trackName: "", artistName: track.artist, collectionName: track.album, artworkUrl100: URL(string: "https://example.com/cover.jpg"))
        #expect(CatalogMatcher.albumMatch(for: track, results: [otherArtist, otherEdition, notApple]) == nil)
    }
    @Test func testClearingGetsPriorityButStillHonorsBurstBudget() {
        var budget = PublicationBudget()
        budget.record(at: epoch)
        #expect(budget.delay(at: epoch.addingTimeInterval(0.2)) > 0)
        #expect(budget.delay(at: epoch.addingTimeInterval(0.2), clearing: true) == 0)
        for i in 1...4 { budget.record(at: epoch.addingTimeInterval(Double(i))) }
        #expect(budget.delay(at: epoch.addingTimeInterval(10), clearing: true) == 10)
        #expect(budget.delay(at: epoch.addingTimeInterval(21), clearing: true) == 0)
    }
    @Test func testFrameBoundsAndByteOrder() throws {
        let frame = RPCFrame(opcode: 3, payload: Data("hello".utf8))
        #expect(Array(frame.encoded().prefix(8)) == [3, 0, 0, 0, 5, 0, 0, 0])
        #expect(throws: RPCError.self) { try RPCFrame.header(Data([1, 0, 0, 0, 255, 255, 255, 255])) }
    }
    @Test func testFragmentedIPCReadsAndPingResponse() throws {
        var fds: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        let client = DiscordSocket(descriptor: fds[0])
        let peer = fds[1]
        // This end writes raw fragments, so it needs its own SIGPIPE protection
        // and bounded blocking I/O if the client times out or closes early.
        var one: Int32 = 1
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        defer { client.close() }
        guard setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0,
              setsockopt(peer, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
              setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            let error = RPCError.system(errno)
            Darwin.close(peer)
            throw error
        }
        let done = DispatchGroup(); done.enter()
        // Never queue the peer behind tests that block waiting for its reply.
        Thread.detachNewThread {
            defer { Darwin.close(peer); done.leave() }
            do {
                let ping = RPCFrame(opcode: 3, payload: Data("heartbeat".utf8)).encoded()
                let ready = RPCFrame(opcode: 1, payload: Data("{\"evt\":\"READY\"}".utf8)).encoded()
                for byte in ping + ready {
                    var byte = byte
                    var written: Int
                    repeat { written = Darwin.write(peer, &byte, 1) } while written < 0 && errno == EINTR
                    guard written == 1 else { throw RPCError.system(errno) }
                }
                let expected = RPCFrame(opcode: 4, payload: Data("heartbeat".utf8)).encoded()
                var pong = Data(count: expected.count)
                var count = 0
                while count < expected.count {
                    let amount = pong.withUnsafeMutableBytes {
                        Darwin.read(peer, $0.baseAddress!.advanced(by: count), expected.count - count)
                    }
                    if amount < 0 && errno == EINTR { continue }
                    guard amount > 0 else { throw RPCError.disconnected }
                    count += amount
                }
                #expect(pong == expected)
            } catch {
                Issue.record(error)
            }
        }
        defer {
            client.close()
            #expect(done.wait(timeout: .now() + 3) == .success)
        }
        let response = try client.response(until: Date().addingTimeInterval(2))
        #expect(response["evt"] as? String == "READY")
    }
    @Test func testDisconnectedRPCDoesNotLeaveACommandHanging() throws {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        let client = DiscordSocket(descriptor: fds[0])
        Darwin.close(fds[1])
        let start = Date()
        #expect(throws: RPCError.self) { try client.response(nonce: "missing", until: Date().addingTimeInterval(1)) }
        #expect(Date().timeIntervalSince(start) < 0.5)
    }
}
