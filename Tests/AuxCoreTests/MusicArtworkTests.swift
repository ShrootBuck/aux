import AppKit
import Foundation
import Testing
@testable import AuxCore

private func code(_ value: String) -> OSType { value.utf8.reduce(0) { ($0 << 8) | OSType($1) } }

/// A playing-track object and its library counterpart can have the same
/// persistent ID while exposing different artwork. Reproduce that API behavior.
private final class MusicArtworkFixture {
    struct Item {
        var id = "pj"
        var title = "PJ"
        var artist = "Bossman Dlow & Lil Baby"
        var album = "PJ - Single"
        var albumArtist = ""
        var image: Data?
    }
    static let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!
    var playing = Item()
    var library = [Item(image: image)]
    var queries = 0
    var imageReads: [String] = []
    var changeAfterQuery = false
    var denyArtwork = false
    var requestedAlbum: String?

    var track: Track { .init(id: playing.id, title: playing.title, artist: playing.artist, album: playing.album, duration: 178) }

    func read(_ event: String, _ direct: NSAppleEventDescriptor?) throws -> NSAppleEventDescriptor {
        guard event == "getd", let direct else { throw MusicError.event(-1708, "Unexpected request") }
        if direct.forKeyword( code("want"))?.typeCodeValue == code("cTrk") {
            queries += 1
            requestedAlbum = direct.forKeyword( code("seld"))?.forKeyword( code("obj2"))?.stringValue
            let list = NSAppleEventDescriptor.list()
            for index in library.indices { list.insert(NSAppleEventDescriptor(string: String(index)), at: index + 1) }
            return list
        }
        let property = direct.forKeyword( code("seld"))!.typeCodeValue
        if property == code("pTrk") { return NSAppleEventDescriptor(string: "playing") }
        let container = direct.forKeyword( code("from"))!
        if property == code("pRaw") {
            let key = container.forKeyword( code("from"))!.stringValue!
            imageReads.append(key)
            if denyArtwork { throw MusicError.permissionDenied }
            let item = key == "playing" ? playing : library[Int(key)!]
            guard let image = item.image else { throw MusicError.event(-1728, "Artwork not found") }
            return NSAppleEventDescriptor(descriptorType: code("tdta"), data: image)!
        }
        let key = container.stringValue!
        let item = key == "playing" ? playing : library[Int(key)!]
        let value: String
        switch property {
        case code("pPIS"): value = changeAfterQuery && queries > 0 && key == "playing" ? "next-track" : item.id
        case code("pnam"): value = item.title
        case code("pAlb"): value = item.album
        case code("pArt"): value = item.artist
        case code("pAlA"): value = item.albumArtist
        default: throw MusicError.event(-1708, "Unexpected property")
        }
        return NSAppleEventDescriptor(string: value)
    }
}

struct MusicArtworkTests {
    @Test func playingTrackCoverWinsWithoutLibraryQuery() async throws {
        let fixture = MusicArtworkFixture()
        fixture.playing.image = MusicArtworkFixture.image
        let result = try await MusicBridge(readEvent: fixture.read).artwork(for: fixture.track)
        #expect(result == fixture.playing.image)
        #expect(fixture.queries == 0)
        #expect(fixture.imageReads == ["playing"])
    }

    @Test func missingPlayingCoverRecoversFromLibraryWithSamePersistentID() async throws {
        let fixture = MusicArtworkFixture()
        let result = try await MusicBridge(readEvent: fixture.read).artwork(for: fixture.track)
        #expect(result == MusicArtworkFixture.image)
        #expect(fixture.requestedAlbum == "PJ - Single")
        #expect(fixture.imageReads == ["playing", "0"])
    }

    @Test func albumArtistAllowsDifferentSongCreditsOnSameAlbum() async throws {
        let fixture = MusicArtworkFixture()
        fixture.playing.albumArtist = "Bossman Dlow"
        fixture.library = [.init(id: "sibling", title: "ION WANNA HEAR IT", artist: "Bossman Dlow", albumArtist: "Bossman Dlow", image: MusicArtworkFixture.image)]
        #expect(try await MusicBridge(readEvent: fixture.read).artwork(for: fixture.track) == MusicArtworkFixture.image)
    }

    @Test func wrongArtistAndDifferentEditionNeverSupplyArtwork() async throws {
        let fixture = MusicArtworkFixture()
        fixture.library = [
            .init(artist: "Cover Band", image: MusicArtworkFixture.image),
            .init(album: "PJ (Live) - Single", image: MusicArtworkFixture.image)
        ]
        #expect(try await MusicBridge(readEvent: fixture.read).artwork(for: fixture.track) == nil)
        #expect(fixture.imageReads == ["playing"])
    }

    @Test func conflictingAlbumArtistsRejectEvenMatchingSongArtist() async throws {
        let fixture = MusicArtworkFixture()
        fixture.playing.albumArtist = "Album Artist One"
        fixture.library[0].albumArtist = "Album Artist Two"
        #expect(try await MusicBridge(readEvent: fixture.read).artwork(for: fixture.track) == nil)
    }

    @Test func trackChangeDuringLibraryLookupDiscardsOldCover() async throws {
        let fixture = MusicArtworkFixture()
        fixture.changeAfterQuery = true
        do {
            _ = try await MusicBridge(readEvent: fixture.read).artwork(for: fixture.track)
            Issue.record("Expected a track-changed error")
        } catch MusicError.trackChanged {} catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test func permissionFailureIsNotSilentlyReportedAsMissingArtwork() async throws {
        let fixture = MusicArtworkFixture()
        fixture.denyArtwork = true
        do {
            _ = try await MusicBridge(readEvent: fixture.read).artwork(for: fixture.track)
            Issue.record("Expected a permission error")
        } catch MusicError.permissionDenied {} catch { Issue.record("Unexpected error: \(error)") }
        #expect(fixture.queries == 0)
    }

    @Test func repeatedMissingLibraryArtworkHasBoundedWork() async throws {
        let fixture = MusicArtworkFixture()
        fixture.library = Array(repeating: .init(), count: 50)
        #expect(try await MusicBridge(readEvent: fixture.read).artwork(for: fixture.track) == nil)
        #expect(fixture.imageReads.count == 5) // Playing object plus at most four library reads.
    }

    @Test func blankAlbumCannotMatchUnrelatedLibraryTracks() async throws {
        let fixture = MusicArtworkFixture()
        fixture.playing.album = " "
        #expect(try await MusicBridge(readEvent: fixture.read).artwork(for: fixture.track) == nil)
        #expect(fixture.queries == 0)
    }
}
