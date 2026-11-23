import Core
import Foundation
import Testing

@testable import Features

/// **Operating the overlays as a rule, pinned down.**
///
/// The same separation as with the focus paths from P14: what is decided
/// stands as a calculation over values and is thus checkable; the view follows it.
@Suite("Live overlay")
/// On the main actor, because the rules being checked live there (AP15,
/// 2026-09-02): the warning gate turns "nonisolated calls MainActor" into a
/// failure — and in substance it always was one.
@MainActor
struct LiveOverlayTests {

    static func channel(_ id: String, group: String?) -> Channel {
        Channel(
            id: id, name: id, streamURL: URL(string: "http://x/\(id)")!,
            playlistID: "p", group: group
        )
    }

    // MARK: - Wrap-around

    /// **tvOS has no natural wraparound.** Arriving at the bottom, nothing
    /// happens, and one keeps pressing until one thinks the app has hung.
    @Test("Arriving at the bottom, one comes out at the top")
    func wrapsAtTheBottom() {
        let rows = ["a", "b", "c"]
        #expect(LiveOverlay.wrapped(from: "c", by: 1, in: rows) == "a")
    }

    @Test("And arriving at the top, at the bottom")
    func wrapsAtTheTop() {
        let rows = ["a", "b", "c"]
        #expect(LiveOverlay.wrapped(from: "a", by: -1, in: rows) == "c")
    }

    /// **Nothing may happen in the middle of the list** — and that is not a
    /// nicety but the fix for a bug: `onMoveCommand` also arrives
    /// when focus has already moved. Whoever advances here as well
    /// jumps two rows on one press (viewer finding 2026-08-11).
    @Test("In the middle of the list the focus moves itself")
    func doesNothingInsideTheList() {
        let rows = ["a", "b", "c"]
        #expect(LiveOverlay.wrapped(from: "a", by: 1, in: rows) == nil)
        #expect(LiveOverlay.wrapped(from: "c", by: -1, in: rows) == nil)
        #expect(LiveOverlay.wrapped(from: "b", by: 1, in: rows) == nil)
    }

    /// A list with one entry does not wrap around — that would be a movement
    /// that moves nothing, and would look like a bug.
    @Test("Where there is nothing to wrap around, nothing happens")
    func nothingToWrap() {
        #expect(LiveOverlay.wrapped(from: "a", by: 1, in: ["a"]) == nil)
        #expect(LiveOverlay.wrapped(from: "a", by: 1, in: []) == nil)
        #expect(LiveOverlay.wrapped(from: nil, by: 1, in: ["a", "b"]) == nil)
        // A row that does not exist is not a starting point.
        #expect(LiveOverlay.wrapped(from: "x", by: 1, in: ["a", "b"]) == nil)
    }

    // MARK: - Groups

    /// **The groups come from the channels**, not from a second source:
    /// that would be a second place where the same information can go stale.
    ///
    /// **And this check paid off immediately.** The function was first called
    /// `groups(in:)` — exactly like the property it calls.
    /// Swift resolved `Self.groups(in: stock)` to the property itself, and
    /// the call recursed endlessly. It compiled without a single warning;
    /// on the TV it would have been a crash when opening the groups.
    @Test("The groups stand in the order of their first appearance")
    func groupsKeepTheirOrder() {
        let channels = [
            Self.channel("1", group: "TR · Genel"),
            Self.channel("2", group: "DE · Nachrichten"),
            Self.channel("3", group: "TR · Genel"),
            Self.channel("4", group: "DE · Sport"),
        ]
        #expect(
            LiveOverlay.groupNames(in: channels) == ["TR · Genel", "DE · Nachrichten", "DE · Sport"])
    }

    /// Channels without a group exist; an empty row in the group list would be
    /// a row with nothing behind it.
    @Test("Channels without a group bring no empty row")
    func channelsWithoutGroup() {
        let channels = [
            Self.channel("1", group: nil),
            Self.channel("2", group: ""),
            Self.channel("3", group: "Sport"),
        ]
        #expect(LiveOverlay.groupNames(in: channels) == ["Sport"])
    }

    // MARK: - The running programme

    /// **Without an anchor one reads clock times** to find one's bearings. The running
    /// show is the place from which "what is still to come" is a question
    /// at all.
    @Test("Exactly one programme is running, and it is the right one")
    func exactlyOneIsRunning() {
        let start = Date(timeIntervalSince1970: 1_723_000_000)
        let programmes = (0..<5).map { index in
            Programme(
                id: "p\(index)", channelID: "c", title: "Sendung \(index)",
                start: start.addingTimeInterval(Double(index) * 3600),
                end: start.addingTimeInterval(Double(index + 1) * 3600)
            )
        }

        let now = start.addingTimeInterval(2.5 * 3600)
        let running = programmes.filter { $0.isRunning(at: now) }
        #expect(running.count == 1)
        #expect(running.first?.id == "p2")

        // Exactly on the boundary the time belongs to the show that is starting, not
        // the one that is ending — otherwise two run for a moment.
        #expect(programmes[1].isRunning(at: start.addingTimeInterval(2 * 3600)) == false)
        #expect(programmes[2].isRunning(at: start.addingTimeInterval(2 * 3600)))
    }
}

/// **Where the channel list opens — group and cursor.**
///
/// Both together, because on the TV it is one operation: whoever presses
/// left wants to see the list they are in, and the cursor on the
/// channel they are currently watching (user request 2026-08-11).
@Suite("Live overlay · entry")
/// On the main actor, because the rules being checked live there (AP15,
/// 2026-09-02): the warning gate turns "nonisolated calls MainActor" into a
/// failure — and in substance it always was one.
@MainActor
struct LiveOverlayOpeningTests {

    static func channel(_ id: String, group: String?) -> Channel {
        Channel(
            id: id, name: id, streamURL: URL(string: "http://x/\(id)")!,
            playlistID: "p", group: group
        )
    }

    static let hevc = channel("10", group: "TR HEVC")
    static let sport = channel("77", group: "Sport")

    // MARK: - The applicable group

    /// **The finding of 2026-08-11**: the channel list always opens HEVC, although the
    /// currently running show is from a different group. Without an
    /// explicit choice, the group of the running channel therefore applies and
    /// not the one the player was entered with.
    @Test("Without a choice the group of the running channel applies")
    func choiceFollowsTheRunningChannel() {
        #expect(LiveOverlay.GroupChoice.ofCurrentChannel.group(current: Self.sport) == "Sport")
        #expect(LiveOverlay.GroupChoice.ofCurrentChannel.group(current: Self.hevc) == "TR HEVC")
    }

    @Test("An explicit choice beats the running channel")
    func explicitChoiceWins() {
        // Whoever chooses "Sports" in the player and then watches an HEVC channel has
        // made their choice — it holds until they make another.
        #expect(LiveOverlay.GroupChoice.named("Sport").group(current: Self.hevc) == "Sport")
        #expect(LiveOverlay.GroupChoice.all.group(current: Self.hevc) == nil)
    }

    /// A channel without a group must not restrict the list to "nothing".
    @Test("Without a group on the running channel it stays on all")
    func noGroupMeansAll() {
        #expect(
            LiveOverlay.GroupChoice.ofCurrentChannel
                .group(current: Self.channel("1", group: nil)) == nil)
        #expect(LiveOverlay.GroupChoice.ofCurrentChannel.group(current: nil) == nil)
    }

    // MARK: - The cursor

    /// Requirement: when the user is on channel 10, the cursor should be on 10 when the list opens,
    /// and not somewhere else.
    @Test("The cursor stands on the running channel")
    func cursorSitsOnTheRunningChannel() {
        let list = [Self.channel("8", group: "TR HEVC"), Self.hevc, Self.channel("11", group: "TR HEVC")]
        #expect(LiveOverlay.openingRow(current: Self.hevc, in: list) == "10")
    }

    /// **And if it is not in the list, the first row** — not
    /// "nothing": a focus that nobody holds takes the movement commands from the overlay,
    /// and it could no longer be closed.
    @Test("If the running channel is not in the list, the first row applies")
    func cursorFallsBackToTheFirstRow() {
        let list = [Self.channel("8", group: "Sport"), Self.sport]
        #expect(LiveOverlay.openingRow(current: Self.hevc, in: list) == "8")
        #expect(LiveOverlay.openingRow(current: nil, in: list) == "8")
        #expect(LiveOverlay.openingRow(current: Self.hevc, in: []) == nil)
    }
}
