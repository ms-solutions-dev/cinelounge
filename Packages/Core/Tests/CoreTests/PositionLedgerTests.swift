import Foundation
import Testing

@testable import Core

/// Tests the progress ledger — **the place where a person's progress lives** (AP42,
/// 2026-09-21).
///
/// Above all it checks what nobody would notice losing: an entry that stays
/// behind empty; a fact sheet that lifts a title into "Continue Watching" where it
/// has no business; a journal that grows without limit.
@Suite("Position ledger")
struct PositionLedgerTests {

    private let now = Date(timeIntervalSince1970: 1_758_000_000)

    // MARK: - Buchen

    @Test("An event then appears in the state and in the outbox")
    func postWritesBoth() {
        var ledger = StillLedger()
        ledger.record(.senderGewaehlt(list: "xtream|panel|user", channels: "a#xtream#1"), on: now)

        #expect(ledger.state.lastChannel["xtream|panel|user"] == "a#xtream#1")
        #expect(ledger.journal.count == 1)
        #expect(ledger.journal[0].time == now)
    }

    /// **The idea from ``LiveMemory``:** whoever selects "Live" without a list should
    /// continue where they were.
    @Test("The chosen channel also counts as 'last overall'")
    func lastOverall() {
        var ledger = StillLedger()
        ledger.record(.senderGewaehlt(list: "xtream|panel|user", channels: "a#xtream#1"), on: now)

        #expect(ledger.state.lastChannel[""] == "a#xtream#1")
    }

    @Test("An event without a list writes only the general state")
    func withoutListOnlyGeneral() {
        var ledger = StillLedger()
        ledger.record(.senderGewaehlt(list: "", channels: "a#xtream#1"), on: now)

        #expect(ledger.state.lastChannel == ["": "a#xtream#1"])
    }

    /// **Even when nothing changes in the state.** The second "favourite set" is the
    /// proof that this person wanted it now — and it decides in the reconciliation
    /// against an older "deleted" from the other device.
    @Test("The same thing twice yields two entries in the outbox")
    func sameTwice() {
        var ledger = StillLedger()
        ledger.record(.senderfavorit(key: "dasnordlicht", true), on: now)
        ledger.record(.senderfavorit(key: "dasnordlicht", true), on: now.addingTimeInterval(60))

        #expect(ledger.state.channelFavorites == ["dasnordlicht"])
        #expect(ledger.journal.count == 2)
    }

    // MARK: - Die Stelle in einem Titel

    @Test("The first ten seconds are not a started film")
    func peekedIn() {
        var ledger = StillLedger()
        ledger.record(.titlePosition(title: "l#movie#7", location: 8, duration: 5400), on: now)

        #expect(ledger.state.titlePositions["l#movie#7"] == nil)
    }

    /// **As with the media server**, and the direction is the one that is built backwards: the
    /// *Unwatched* mark resets, the Watched mark does not. A ticked-off title
    /// drops out of "Continue Watching" because that is filtered by ``seen``.
    @Test("Unwatched resets the position, watched leaves it")
    func unwatchedResets() {
        var ledger = StillLedger()
        ledger.record(.titlePosition(title: "l#movie#7", location: 600, duration: 5400), on: now)

        ledger.record(.seen(title: "l#movie#7", true), on: now)
        #expect(ledger.state.titlePositions["l#movie#7"]?.location == 600)
        #expect(ledger.state.titlePositions["l#movie#7"]?.seen == true)

        ledger.record(.seen(title: "l#movie#7", false), on: now)
        #expect(ledger.state.titlePositions["l#movie#7"] == nil)
    }

    @Test("An entry with nothing left on it disappears")
    func emptyEntryDisappears() {
        var ledger = StillLedger()
        ledger.record(.titlePosition(title: "l#movie#7", location: 600, duration: 5400), on: now)
        ledger.record(.titlePosition(title: "l#movie#7", location: 0, duration: nil), on: now)

        #expect(ledger.state.titlePositions.isEmpty)
    }

    // MARK: - Der Steckbrief

    /// **With 27,558 movies this is no dictionary anymore.** The finding comes from
    /// ``PlaylistKit/VODMemory`` and applies here unchanged.
    @Test("A profile card creates no entry")
    func profileCardDoesNotCreate() {
        var ledger = StillLedger()
        ledger.record(.profileCard(title: "l#movie#7", name: "Stille", kind: .movie, image: "p1"), on: now)

        #expect(ledger.state.titlePositions.isEmpty)
    }

    @Test("A profile card does not reorder Continue Watching")
    func profileCardLeavesOrderUntouched() {
        var ledger = StillLedger()
        ledger.record(.titlePosition(title: "l#movie#7", location: 600, duration: 5400), on: now)
        ledger.record(
            .profileCard(title: "l#movie#7", name: "Stille", kind: .movie, image: "p1"),
            on: now.addingTimeInterval(9_999))

        #expect(ledger.state.titlePositions["l#movie#7"]?.recent == now)
        #expect(ledger.state.titlePositions["l#movie#7"]?.title == "Stille")
    }

    /// **A list has thousands of entries.** As an event, the fact sheet filled the
    /// outbox in a single pass and pushed out every channel switch.
    @Test("A profile card does not go into the outbox")
    func profileCardDoesNotGoIntoThePost() {
        var ledger = StillLedger()
        ledger.record(.titlePosition(title: "l#movie#7", location: 600, duration: 5400), on: now)
        ledger.record(.profileCard(title: "l#movie#7", name: "Stille", kind: .movie, image: "p1"), on: now)

        #expect(ledger.journal.count == 1)
        #expect(ledger.state.titlePositions["l#movie#7"]?.title == "Stille")
    }

    /// AP63, 2026-10-01: an Xtream episode cannot be fetched individually — its tile in
    /// "Continue Watching" knows the series only from the fact sheet.
    @Test("The profile card remembers the series, and one without a series does not erase it")
    func profileCardRemembersSeries() {
        var ledger = StillLedger()
        ledger.record(.titlePosition(title: "l#episode#9", location: 600, duration: 2400), on: now)
        ledger.record(
            .profileCard(
                title: "l#episode#9", name: "Folge", kind: .episode, image: nil, series: "l#series#3"),
            on: now)
        ledger.record(.profileCard(title: "l#episode#9", name: "Folge", kind: .episode, image: "p"), on: now)
        #expect(ledger.state.titlePositions["l#episode#9"]?.series == "l#series#3")
    }

    @Test("A state without a series reads as before")
    func progressWithoutSeriesReads() throws {
        let legacyJSON = #"{"stelle":600,"dauer":2400,"gesehen":false,"favorit":false,"titel":"Folge"}"#
        let location = try JSONDecoder().decode(
            StateRecording.TitlePosition.self, from: Data(legacyJSON.utf8))
        #expect(location.series == nil)
        #expect(location.title == "Folge")
    }

    // MARK: - Die Ausgangspost

    @Test("The journal does not grow past its maximum")
    func journalIsCapped() {
        var ledger = StillLedger()
        for number in 0...StillLedger.maximumCount {
            ledger.record(.senderGewaehlt(list: "l", channels: "s\(number)"), on: now)
        }

        #expect(ledger.journal.count == StillLedger.maximumCount)
        // **The oldest drops out, not the newest.** The other way around the
        // outbox would stay at the state from a thousand events ago.
        #expect(ledger.journal.first?.event == .senderGewaehlt(list: "l", channels: "s1"))
    }

    @Test("Acknowledging takes from the front")
    func acknowledgeTakesFromFront() {
        var ledger = StillLedger()
        ledger.record(.senderGewaehlt(list: "l", channels: "a"), on: now)
        ledger.record(.senderGewaehlt(list: "l", channels: "b"), on: now)
        ledger.record(.senderGewaehlt(list: "l", channels: "c"), on: now)

        ledger.acknowledge(2)

        #expect(ledger.journal.count == 1)
        #expect(ledger.journal[0].event == .senderGewaehlt(list: "l", channels: "c"))
        // The state stays as it is — what is acknowledged is the mail, not the truth.
        #expect(ledger.state.lastChannel["l"] == "c")
    }

    @Test("Acknowledging more than there is empties the outbox without crashing")
    func acknowledgePastTheEnd() {
        var ledger = StillLedger()
        ledger.record(.senderGewaehlt(list: "l", channels: "a"), on: now)

        ledger.acknowledge(99)

        #expect(ledger.journal.isEmpty)
    }

    // MARK: - Ablage

    @Test("Two profiles, two ledgers")
    func twoProfilesTwoLedgers() {
        let store = InMemoryStore()
        var parents = StillLedger()
        parents.record(.titlePosition(title: "l#movie#7", location: 600, duration: 5400), on: now)
        parents.write(in: store, forItem: "parents")

        var kind = StillLedger()
        kind.record(.titlePosition(title: "l#movie#9", location: 120, duration: 3600), on: now)
        kind.write(in: store, forItem: "child")

        #expect(
            StillLedger.read(from: store, forItem: "parents").state.titlePositions.keys.sorted() == [
                "l#movie#7"
            ])
        #expect(
            StillLedger.read(from: store, forItem: "child").state.titlePositions.keys.sorted() == [
                "l#movie#9"
            ])
        // The device base stays empty — it holds the state from before the first setup.
        #expect(StillLedger.read(from: store) == StillLedger())
    }

    @Test("An empty ledger creates no file")
    func emptyLedgerStoresNothing() {
        let store = InMemoryStore()
        StillLedger().write(in: store, forItem: "parents")

        #expect((try? store.value(for: StillLedger.key(forItem: "parents"))) == nil)
    }

    /// **Otherwise an update would take the viewer's state away.** Same reason as for
    /// ``ShelfOrder/init(from:)``.
    @Test("A file without the journal is still readable")
    func fieldsMayBeMissing() {
        let store = InMemoryStore()
        try? store.set(
            #"{"stand":{"letzterSender":{"l":"a"}}}"#, for: StillLedger.key(forItem: "parents"))

        let ledger = StillLedger.read(from: store, forItem: "parents")
        #expect(ledger.state.lastChannel["l"] == "a")
        #expect(ledger.journal.isEmpty)
    }

    @Test("Channel favorites are sorted — two equal states look equal")
    func favoritesSorted() {
        var ledger = StillLedger()
        ledger.record(.senderfavorit(key: "zinne", true), on: now)
        ledger.record(.senderfavorit(key: "dasnordlicht", true), on: now)

        #expect(ledger.state.channelFavorites == ["dasnordlicht", "zinne"])
    }

    @Test("The group order arrives as a single action")
    func groupOrder() {
        var ledger = StillLedger()
        ledger.record(
            .senderreihenfolge(groups: ["Sport", "Nachrichten"], hidden: ["Erwachsene"]),
            on: now)

        #expect(ledger.state.groupOrder == ["Sport", "Nachrichten"])
        #expect(ledger.state.hiddenGroups == ["Erwachsene"])
    }

    // MARK: - Retrospect

    @Test("A caught-up broadcast is a title like any other for the ledger")
    func recapIsATitle() {
        let identifier = StateIdentifier.catchUp(
            list: "xtream|panel|user", channels: "s7", from: now)
        var ledger = StillLedger()
        ledger.record(.titlePosition(title: identifier, location: 900, duration: 3600), on: now)

        #expect(ledger.state.titlePositions[identifier]?.location == 900)
        // **The list identifier comes first** — that is how ``ListMigration`` takes it along.
        #expect(identifier.hasPrefix("xtream|panel|user#"))
    }

    @Test("The same broadcast yields the same identifier on two devices")
    func recapIsLocationIndependent() {
        let single = StateIdentifier.catchUp(list: "l", channels: "s7", from: now)
        let other = StateIdentifier.catchUp(list: "l", channels: "s7", from: now)

        #expect(single == other)
        #expect(
            single != StateIdentifier.catchUp(list: "l", channels: "s7", from: now.addingTimeInterval(3600)))
    }
}
