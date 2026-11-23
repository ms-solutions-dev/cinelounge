import Foundation
import SourceProbe
import Testing

@testable import FeaturesPhone

/// The history across all sources — four rules, each with its case.
@Suite("History")
struct HistoryTests {

    private func entry(
        _ identifier: String, _ origin: Catalog.Origin, hoursAgo: Double = 0
    ) -> HistoryEntry {
        HistoryEntry(
            identifier: identifier, origin: origin, title: identifier,
            timestamp: Date(timeIntervalSinceNow: -hoursAgo * 3600))
    }

    /// **Only the latest per title and per channel.** Without this rule an evening of zapping fills
    /// the whole shelf, and the series in progress stands at position twelve.
    @Test("A second entry replaces the first")
    func onlyTheLast() {
        var history = History()
        history.note(entry("ahorn", .channelList))
        history.note(entry("zinne", .channelList))
        history.note(entry("ahorn", .channelList))
        #expect(history.entries.count == 2)
        // The newest stands first.
        #expect(history.entries.first?.identifier == "ahorn")
    }

    /// **Origin and ID together.** Two services can assign the same number; a
    /// history that confuses them leads to the wrong title.
    @Test("The same identifier under two services makes two entries")
    func originCountsToo() {
        var history = History()
        history.note(entry("42", .jellyfin))
        history.note(entry("42", .provider))
        #expect(history.entries.count == 2)
    }

    /// Twenty, because the shelf carries twenty tiles. Keeping more would mean storing
    /// something that no view ever shows.
    @Test("It does not grow beyond the shelf")
    func upperLimit() {
        var history = History()
        for index in 0..<30 { history.note(entry("\(index)", .jellyfin)) }
        #expect(history.entries.count == History.atMost)
        // The youngest stays, the oldest drops.
        #expect(history.entries.first?.identifier == "29")
        #expect(!history.entries.contains { $0.identifier == "0" })
    }

    /// **Live expires, recorded content does not.** A channel from the day before yesterday is not a
    /// "continue watching"; a movie one has watched half of two weeks ago very
    /// well is. A channel keeps running whether one is watching or not.
    @Test("A channel expires after six hours, a film never")
    func expiry() {
        var history = History()
        history.note(entry("sender", .channelList, hoursAgo: 7))
        history.note(entry("film", .jellyfin, hoursAgo: 14 * 24))

        let state = CatalogState.fromAccesses(jellyfin: true, channelList: true)
        let isValid = history.validOnes(at: state).map(\.identifier)
        #expect(isValid == ["film"])

        // Five hours old is still the same evening.
        var fresh = History()
        fresh.note(entry("sender", .channelList, hoursAgo: 5))
        #expect(fresh.validOnes(at: state).count == 1)
    }

    /// **An entry disappears with its source.** If the portal is switched off or
    /// the channel list deleted, the tile is a button that leads to an error
    /// message — worse than no tile.
    @Test("An entry drops out without its source")
    func orphaned() {
        var history = History()
        history.note(entry("film", .jellyfin))
        history.note(entry("portal", .portals))

        let lacksPortals = CatalogState.fromAccesses(jellyfin: true)
        #expect(history.validOnes(at: lacksPortals).map(\.identifier) == ["film"])
    }

    /// **Writing happens on playback and nowhere else.** The finding of 2026-09-02 in the
    /// TV program stands as a warning for that: The channel reminder was written in **four**
    /// places, all four lay **before** the player — and whoever switched in the player
    /// got past none of them.
    ///
    /// **Since AP14 it exists, and it is exactly one:** ``PlayerModel``. This check
    /// establishes that, so that a second one gets noticed before it does damage.
    ///
    /// **What is counted is saving, not noting.** "Noting" means something different in this app in
    /// several places — `PhoneEvent.note()` writes to the error ledger,
    /// and a pattern on it would count that too. Whoever really changes the history must
    /// **save** it; that is unambiguous.
    ///
    /// **On 2026-09-07 it triggered once, and that was right.** The long press on
    /// a tile ("mark as watched") must take the entry out, otherwise
    /// the tile stays — and the first version did that with its own
    /// `load` / `remove` / `save` in the view. What this check is meant to prevent
    /// are second places that **create** a history; removing cannot do the
    /// damage this is about. It therefore got a name and a place
    /// — ``HistoryStore/remove(_:origin:)`` — instead of weakening
    /// the rule.
    @Test("There is exactly one write location, and it lies in the player")
    func singleWriter() throws {
        var locations: [String] = []
        for file in try SourceText.files(in: .featuresPhone)
        where file.content.contains("HistoryStore.shared.save(") {
            locations.append(file.relative)
        }
        // **Exactly one, and it lies at the end of playback.** The TV program had
        // four, all BEFORE the player — and whoever switched in it got past none.
        #expect(locations.count == 1, "Write locations: \(locations)")
        #expect(locations.first?.contains("Spieler") == true, "Write locations: \(locations)")
    }

    // MARK: - The portals (07.09.)

    /// **A switched-off portal drops out, a running one stays.**
    ///
    /// The finding: flatone had been set inactive, and its titles
    /// still stood under "Continue Watching". ``History/validOnes(at:portals:now:)``
    /// had until then checked only ``CatalogState/hasKey(_:)`` — that is, the origin as a whole.
    @Test("A switched-off portal disappears from the history")
    func portalDropsOut() {
        var history = History()
        history.note(entry("serieshub|s1|/a", .portals))
        history.note(entry("flatone|s2|/b", .portals))
        let isValid = history.validOnes(
            at: .fromAccesses(portals: true), portals: ["serieshub"])
        #expect(isValid.count == 1)
        #expect(isValid.first?.identifier.hasPrefix("serieshub") == true)
    }

    /// **`nil` means "nobody asked" and filters nothing.**
    ///
    /// Without this distinction every caller without portal knowledge — and every start
    /// without a reachable bridge — would lose the entire portal history instead of merely not checking it.
    @Test("Nothing is filtered without portal information")
    func withoutInformationEverythingStays() {
        var history = History()
        history.note(entry("flatone|s2|/b", .portals))
        #expect(history.validOnes(at: .fromAccesses(portals: true)).count == 1)
        // An empty set, by contrast, is a statement: no portal counts.
        #expect(
            history.validOnes(at: .fromAccesses(portals: true), portals: []).isEmpty)
    }

    /// **An ID without a readable portal stays.**
    ///
    /// It comes from a state that this version does not know; throwing it out would be
    /// a statement nobody has substantiated — same rule as for an unknown
    /// origin in ``HistoryStore``.
    @Test("An unreadable portal identifier is not discarded")
    func unreadableIdentifierStays() {
        var history = History()
        history.note(entry("legacy-without-separator", .portals))
        #expect(
            history.validOnes(at: .fromAccesses(portals: true), portals: []).count == 1)
    }

    /// **Removing hits exactly one entry** — ID **and** origin.
    @Test("Removing takes only the one entry")
    func removalHitsOne() {
        var history = History()
        history.note(entry("42", .jellyfin))
        history.note(entry("42", .provider))
        history.remove("42", origin: .jellyfin)
        #expect(history.entries.count == 1)
        #expect(history.entries.first?.origin == .provider)
    }

    /// **The series must survive the disk** — the finding of 2026-09-07.
    ///
    /// ``HistoryEntry/series`` has existed since E38, but `HistoryStore.Stored` did
    /// not: it was never written, never read. The whole chain ("the
    /// detail page passes its ID along, the history writes it, the tile carries it")
    /// thereby ended **at program start** — and with a portal the series cannot be
    /// derived from an episode ID. Within a session it went unnoticed because the store
    /// keeps the entry completely in memory.
    @Test("The history carries the series across a restart")
    func seriesSurvivesTheDisk() async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }

        var history = History()
        history.note(
            HistoryEntry(
                identifier: "serieshub|s1|/1-wendetag", origin: .portals,
                title: "Morrowfeld", series: "serieshub|s1|/morrowfeld"))
        await HistoryStore(folder: folder).save(history)

        // **A second store on the same folder is the restart.** Asking the same one
        // again would check only the cache, that is exactly the place where it never
        // snagged.
        let read = await HistoryStore(folder: folder).load()
        #expect(read.entries.first?.series == "serieshub|s1|/morrowfeld")
        #expect(read.entries.first?.tile.series == "serieshub|s1|/morrowfeld")
    }

    /// **The condition under which ``FileProtectionType/complete`` is right** — AP10,
    /// 2026-09-07.
    ///
    /// Since that day the history has been under the strictest protection class: On a
    /// **locked** device the file is not readable. That is correct as long as it is
    /// read only in the foreground — player, Home screen, portals —, and exactly that is
    /// the case today.
    ///
    /// **If a background task were added, it would break silently.** It would read an empty file
    /// on the locked device, "Continue Watching" would be empty, and there would be **no error**:
    /// ``HistoryStore/load()`` creates an empty history on a read error. Whoever builds the
    /// first background task must decide the protection class too — and this
    /// check is the place where they learn of it.
    ///
    /// **Searched in the source text and not in the behavior**, as with "exactly one
    /// write place" further up: A background task cannot be triggered in a check,
    /// but its registration can very well be found.
    @Test("No background task that could read the protected history")
    func noBackgroundTask() throws {
        var found: [String] = []
        for file in try SourceText.files(in: .phone) {
            guard !file.relative.hasSuffix("HistoryTests.swift") else { continue }
            // **The call and not the name** — otherwise the check finds the
            // comment that refers to it. Exactly that happened on the first run:
            // `HistoryStore` names `BGTaskScheduler` in its justification, and the check
            // reported the very file it is supposed to protect. What is searched for is therefore what a
            // registration really writes.
            if ["BGTaskScheduler.shared", ".beginBackgroundTask"].contains(where: {
                file.content.contains($0)
            }) {
                found.append(file.relative)
            }
        }
        #expect(
            found.isEmpty,
            "Background task found: \(found) — then the protection class of the history store must be decided again."
        )
    }
}
