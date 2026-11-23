import Foundation
import Testing

@testable import Core

/// **Both rules about adult channels — measured per list** (check Live, finding 1).
///
/// Since 2026-09-27 the block is applied at the source (`LiveLibrary`); that it takes
/// effect there on every path is checked by `ChannelSourceFilterTests` in PlaylistKit.
@Suite("Channel lock")
struct ChannelBlockTests {

    private static func channel(_ id: String, list: String, adult: Bool = false) -> Channel {
        Channel(
            id: id, name: id, streamURL: URL(string: "https://example.test/\(id)")!,
            playlistID: list, isAdult: adult)
    }

    private static let xtream = [channel("ahorn", list: "x"), channel("rot", list: "x", adult: true)]
    private static let m3u = [channel("a", list: "m"), channel("b", list: "m")]

    @Test("Default: flagged channels stay hidden, everything else stays")
    func preset() {
        #expect(ChannelLock().filter(Self.xtream + Self.m3u).map(\.id) == ["ahorn", "a", "b"])
    }

    @Test("With the switch, flagged channels appear")
    func withSwitch() {
        #expect(ChannelLock(showsAdult: true).filter(Self.xtream).map(\.id) == ["ahorn", "rot"])
    }

    @Test("Second rule: a list without any flagging disappears entirely")
    func unmarked() {
        #expect(ChannelLock(hidesUnlabeled: true).filter(Self.m3u).isEmpty)
    }

    /// **The second rule applies only where the first knows nothing.**
    @Test("Second rule: the flagging list keeps its unflagged channels")
    func labeling() {
        let strict = ChannelLock(hidesUnlabeled: true)
        #expect(strict.filter(Self.xtream).map(\.id) == ["ahorn"])
        let pending = ChannelLock(showsAdult: true, hidesUnlabeled: true)
        #expect(pending.filter(Self.xtream).map(\.id) == ["ahorn", "rot"])
    }

    /// **Per list and not on the whole catalog**: measured on the whole catalog, a
    /// marking access let an M3U list through next to it.
    @Test("Second rule: next to a flagging account the M3U list is dropped anyway")
    func perList() {
        let strict = ChannelLock(hidesUnlabeled: true)
        #expect(strict.filter(Self.xtream + Self.m3u).map(\.id) == ["ahorn"])
    }

    /// **Can be switched off, otherwise half the list disappears.**
    @Test("Without the second rule an M3U list stays complete")
    func m3uStays() {
        #expect(ChannelLock().filter(Self.m3u).count == 2)
    }

    @Test("An Xtream account without any flagging counts as unflagged")
    func marksRecognized() {
        #expect(ChannelLock.labelingLists(Self.m3u).isEmpty)
        #expect(ChannelLock.labelingLists(Self.xtream + Self.m3u) == ["x"])
    }
}
