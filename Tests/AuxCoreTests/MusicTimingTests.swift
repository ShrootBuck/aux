import AppKit
import Foundation
import Testing
@testable import AuxCore

private final class MusicTimingFixture {
    var date = Date(timeIntervalSince1970: 1_700_000_000)
    var positionReadStarted = Date.distantPast
    var state = "kPSP"
    var changedTrack = false
    private var positionWasRead = false
    private func code(_ value: String) -> OSType { value.utf8.reduce(0) { ($0 << 8) | OSType($1) } }

    func read(_ event: String, _ direct: NSAppleEventDescriptor?) throws -> NSAppleEventDescriptor {
        let property = direct?.forKeyword(code("seld"))?.typeCodeValue
        switch property {
        case code("pPlS"): return NSAppleEventDescriptor(enumCode: code(state))
        case code("pTrk"): return NSAppleEventDescriptor(string: "track")
        case code("pPIS"):
            if positionWasRead { date.addTimeInterval(0.8) }
            return NSAppleEventDescriptor(string: changedTrack && positionWasRead ? "next" : "one")
        case code("pnam"), code("pArt"), code("pAlb"):
            date.addTimeInterval(0.1)
            return NSAppleEventDescriptor(string: "Metadata")
        case code("pDur"): return NSAppleEventDescriptor(double: 300)
        case code("pPos"):
            positionReadStarted = date
            date.addTimeInterval(0.04)
            positionWasRead = true
            return NSAppleEventDescriptor(double: 48.125)
        default: throw MusicError.event(-1708, "Unexpected property")
        }
    }
}

struct MusicTimingTests {
    @Test func positionTimestampExcludesMetadataAndValidationLatency() async throws {
        let fixture = MusicTimingFixture()
        let snapshot = try await MusicBridge(readEvent: fixture.read, now: { fixture.date }).snapshot()
        #expect(abs(snapshot.sampledAt.timeIntervalSince(fixture.positionReadStarted) - 0.02) < 0.000001)
        #expect(abs(snapshot.position(at: fixture.date) - 48.945) < 0.000001)
    }

    @Test func pausedPositionDoesNotAdvanceDuringValidation() async throws {
        let fixture = MusicTimingFixture()
        fixture.state = "kPSp"
        let snapshot = try await MusicBridge(readEvent: fixture.read, now: { fixture.date }).snapshot()
        #expect(snapshot.state == .paused)
        #expect(snapshot.position(at: fixture.date) == 48.125)
    }

    @Test func changedTrackStillRejectsTheTimedSample() async throws {
        let fixture = MusicTimingFixture()
        fixture.changedTrack = true
        do {
            _ = try await MusicBridge(readEvent: fixture.read, now: { fixture.date }).snapshot()
            Issue.record("Expected a track-changed error")
        } catch MusicError.trackChanged {}
    }
}
