import Core
import Foundation
import Testing

@testable import PlaylistKit

/// The provider level of the sidebar (roadmap P6): for each stored list its
/// own groups, in the user's ranking — not thrown together.
///
/// Tested against injected sources, not against the network: the scope
/// per list is pure computation on the loaded catalog.
@Suite("Provider groups")
@MainActor
struct LiveLibraryProviderTests {

    /// A source with a fixed catalog.
    private actor FixedSource: ChannelSource {
        let playlist: Playlist
        private let list: [Channel]

        init(playlist: Playlist, channels: [Channel]) {
            self.playlist = playlist
            self.list = channels
        }

        func channels() async throws -> [Channel] { list }

        func programmes(for channelID: String, around date: Date) async throws -> [Programme] {
            []
        }
    }

    private func channel(_ id: String, list: String, group: String?) -> Channel {
        Channel(
            id: id,
            name: id,
            streamURL: URL(string: "http://example/\(id).ts")!,
            playlistID: list,
            group: group
        )
    }

    /// A database of its own per check — in temporary storage and with its own
    /// ID. Without that, all checks would share the app's cache and
    /// would see the channels of the previous one.
    static func freshCache() -> LiveCache {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cinelounge-pruefung-\(UUID().uuidString)")
        return LiveCache(directory: directory)
    }

    private func playlist(_ id: String, name: String) -> Playlist {
        Playlist(id: id, name: name, kind: .m3u(URL(string: "http://example/\(id).m3u")!))
    }

    @Test("Every list gets its own groups, in the user's ranking")
    func groupsPerProvider() async throws {
        let store = PlaylistStore(store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore())
        let home = playlist("eins", name: "Zuhause")
        let bought = playlist("zwei", name: "Gekauft")
        store.add(home)
        store.add(bought)

        let library = LiveLibrary(store: store, cache: Self.freshCache())
        await library.install(
            FixedSource(
                playlist: home,
                channels: [
                    channel("erste", list: "eins", group: "News"),
                    channel("zweite", list: "eins", group: "Sport"),
                ]
            ),
            for: home.id
        )
        await library.install(
            FixedSource(
                playlist: bought,
                channels: [channel("dritte", list: "zwei", group: "News")]
            ),
            for: bought.id
        )

        let providers = await library.providerGroups()

        #expect(providers.map(\.name) == ["Zuhause", "Gekauft"])
        // "News" exists twice — once per provider, not merged.
        #expect(providers.first?.groups == ["News", "Sport"])
        #expect(providers.last?.groups == ["News"])
    }

    @Test("A list without channels does not appear as a provider")
    func emptyListStaysHidden() async throws {
        let store = PlaylistStore(store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore())
        let filled = playlist("eins", name: "Zuhause")
        let empty = playlist("zwei", name: "Leer")
        store.add(filled)
        store.add(empty)

        let library = LiveLibrary(store: store, cache: Self.freshCache())
        await library.install(
            FixedSource(
                playlist: filled,
                channels: [channel("erste", list: "eins", group: "News")]
            ),
            for: filled.id
        )
        await library.install(FixedSource(playlist: empty, channels: []), for: empty.id)

        let providers = await library.providerGroups()

        #expect(providers.map(\.name) == ["Zuhause"])
    }
}

/// What the diagnostics say after a programme-guide sync.
///
/// **The branches decide between tick and cross in the trace** — and thus
/// whether a silent failure can be found in the submitted report.
/// Tested on ``LiveLibrary/guideReport(tally:stored:)``, because the message would otherwise
/// lie behind a network fetch and a database on disk: the branch
/// "read, but nothing arrived" cannot be produced on the computer — it occurred
/// on the device (2026-08-16, Application Support not writable).
@Suite("Report of the program guide sync")
struct GuideReportTests {

    private func report(
        stored: Int, read: Int = 0, attempted: Int = 0, answered: Int = 0, withoutAccess: Int = 0
    ) -> LiveLibrary.GuideReport {
        LiveLibrary.guideReport(
            tally: LiveLibrary.GuideTally(
                attempted: attempted, answered: answered, withoutAccess: withoutAccess,
                read: read),
            stored: stored)
    }

    @Test("What lies in the database is counted, not estimated")
    func storedCountIsTheHeadline() {
        let outcome = report(stored: 61_026, read: 61_026, attempted: 1, answered: 1)
        #expect(outcome.text == "Program guide: 61026 programmes in the cache.")
        #expect(outcome.verdict == .plain)
    }

    @Test("Yesterday's stock is not today's success")
    func staleStockDoesNotMaskAFailedRound() {
        // Until now the failure went only to `Diagnostics.network` — a plain
        // logger with no line in the trace. The report showed a tick above a number
        // from the previous run.
        let outcome = report(stored: 61_026, read: 0, attempted: 2, answered: 0)
        #expect(outcome.verdict == .problem)
        #expect(outcome.text.contains("61026 programmes in the cache"))
        #expect(outcome.text.contains("0 of 2 sources answered"))
    }

    @Test("Read and nothing arrived is the silent failure")
    func readButNothingStored() {
        let outcome = report(stored: 0, read: 61_026, attempted: 1, answered: 1)
        #expect(outcome.verdict == .problem)
        #expect(outcome.text.contains("61026 programmes read"))
        #expect(outcome.text.contains("none arrived in the database"))
    }

    @Test("Whoever did not answer is not declared empty")
    func silenceIsNotEmptiness() {
        let muted = report(stored: 0, read: 0, attempted: 2, answered: 0)
        #expect(muted.verdict == .problem)
        #expect(!muted.text.contains("delivered no programmes"))
        #expect(muted.text.contains("none of the 2 sources answered"))

        let empty = report(stored: 0, read: 0, attempted: 1, answered: 1)
        #expect(empty.verdict == .problem)
        #expect(empty.text.contains("delivered no programmes"))
    }

    @Test("Even a partial outage does not accuse all sources")
    func partialSilenceIsNotEmptinessEither() {
        // The same unsubstantiated accusation one level down: if one of two sources
        // stayed silent, the run says nothing about their guide.
        let outcome = report(stored: 0, read: 0, attempted: 2, answered: 1)
        #expect(outcome.verdict == .problem)
        #expect(!outcome.text.contains("delivered no programmes"))
        #expect(outcome.text.contains("1 of 2 sources answered"))
    }

    @Test("An Xtream list without credentials is not the same as no source at all")
    func missingCredentialsAreNamed() {
        let outcome = report(stored: 0, withoutAccess: 1)
        #expect(outcome.verdict == .problem)
        #expect(outcome.text.contains("without stored credentials"))
        #expect(!outcome.text.contains("no guide source"))
    }

    @Test("Where nothing was asked nobody is accused")
    func nothingAskedIsNoDefect() {
        let outcome = report(stored: 0)
        #expect(outcome.verdict == .plain)
        #expect(outcome.text.contains("no guide source"))
    }
}
