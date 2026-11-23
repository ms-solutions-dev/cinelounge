import Core
import Flows
import Foundation
import Testing

@testable import FeaturesPhone

/// The search across all catalogs: two empty screens, a silent source, and the
/// state at the hit.
@Suite("Search")
struct SearchTests {

    /// **What is awaited is the search job itself and not a state with a deadline.**
    ///
    /// Until 2026-09-25 there was a wait here for a condition with a thirty-second
    /// deadline; in the full suite it ran out on main in two of three runs. Now the
    /// model does not debounce in the check (``SearchViewModel/init(debounce:sources:networkMonitor:)``),
    /// and the check waits for ``SearchViewModel/running`` — as long as the search takes.
    @MainActor
    private static func needle(_ model: SearchViewModel, _ word: String) async {
        model.word = word
        await model.running?.value
    }

    private static func match(_ title: String, state: PortalState? = nil) -> Match {
        Match(tile: TileContent(id: title, title: title), state: state)
    }

    /// **Nothing entered is not a result.** Whoever opens the search should not learn
    /// that nothing was found before they have searched.
    @Test("Without input it is idle and not the empty result")
    @MainActor
    func idleIsNotEmpty() async {
        let model = SearchViewModel(
            debounce: .zero, sources: [TrialSearch(origin: .jellyfin, match: [])])
        #expect(model.state == .idle)
        model.word = "a"
        #expect(model.state == .idle, "one character is below the minimum length")
    }

    /// From two characters — a single letter matches almost everything and says nothing.
    @Test("From two characters on it searches")
    @MainActor
    func fromTwoCharacters() async {
        let model = SearchViewModel(
            sources: [TrialSearch(origin: .jellyfin, match: [Self.match("Selvin")])])
        await Self.needle(model, "ez")
        #expect(model.state == .settled)
        #expect(model.total == 1)
    }

    /// **A group without hits drops out, one without an answer stays.** Otherwise the
    /// viewer counts hits from two catalogs and takes them for all.
    @Test("The silent source stays, the empty one disappears")
    @MainActor
    func silentStaysEmptyGoes() async {
        let model = SearchViewModel(
            debounce: .zero,
            sources: [
                TrialSearch(origin: .jellyfin, match: [Self.match("Selvin")]),
                TrialSearch(origin: .provider, match: []),
                TrialSearch(origin: .portals, match: [], hasAnswered: false),
            ])
        await Self.needle(model, "drugladan")

        #expect(model.groups.map(\.origin) == [.jellyfin, .portals])
    }

    /// Whoever answers first must not decide what stands on top.
    @Test("The order of the groups is that of the sources, not of the answers")
    @MainActor
    func orderIsFixed() async {
        let model = SearchViewModel(
            debounce: .zero,
            sources: [
                TrialSearch(
                    origin: .jellyfin, match: [Self.match("Slow")],
                    delay: .milliseconds(120)),
                TrialSearch(origin: .provider, match: [Self.match("Fast")]),
            ])
        await Self.needle(model, "test")

        #expect(model.groups.map(\.origin) == [.jellyfin, .provider])
    }

    @Test("Without matches the other empty screen is shown")
    @MainActor
    func nothingFound() async {
        let model = SearchViewModel(
            debounce: .zero, sources: [TrialSearch(origin: .jellyfin, match: [])])
        await Self.needle(model, "xyzq")
        #expect(model.state == .nothingFound)
    }

    @Test("Clearing the input leads back to idle")
    @MainActor
    func clearingResets() async {
        let model = SearchViewModel(
            sources: [TrialSearch(origin: .jellyfin, match: [Self.match("Selvin")])])
        await Self.needle(model, "drugladan")
        #expect(model.state == .settled)

        model.clear()
        #expect(model.state == .idle)
        #expect(model.groups.isEmpty)
    }

    // MARK: - The footer for Jellyfin

    /// **A name answers "which server", a number sequence does not.**
    ///
    /// **Invented values, real form.** The first attempt used the machine name of the
    /// home server here — and it would thereby stand in the history forever. The
    /// language-key checker found it because it looked like a key; the
    /// actual error was a different and bigger one. Same rule as for the
    /// error ledger: test data has the form of the real thing and never its content.
    @Test("A raw address is not among the matches, a host name is")
    func onlyNamesAsLabel() {
        #expect(JellyfinSearch.readable("jellyfin.example") == "jellyfin.example")
        #expect(JellyfinSearch.readable("10.0.0.1") == nil)
        #expect(JellyfinSearch.readable("fd00::1") == nil)
        #expect(JellyfinSearch.readable("") == nil)
    }

    // MARK: - The footer for portals

    /// "4 of 4" reads like a warning that is none.
    @Test("When all portals have answered there is no fraction")
    func portalFooterWithoutFraction() {
        let allReady = PortalSearchSource.footer(ready: 3, total: 3)
        let some = PortalSearchSource.footer(ready: 2, total: 3)
        #expect(allReady != nil)
        #expect(some != nil)
        #expect(allReady != some)
        #expect(PortalSearchSource.footer(ready: 0, total: 0) == nil)
    }

    /// **The case that stayed silent.** The number looked right and never was: A portal
    /// without search is by definition not in the bridge's answer, so there it said
    /// permanently "2 of 4" — with four healthy portals.
    @Test("A portal without search does not count in the footer")
    func portalsWithoutSearchDoNotCount() {
        let portals = [
            (id: "serieshub", name: "Serieshub", ready: true, state: "ready", reason: String?.none),
            (id: "animehub", name: "Animehub", ready: true, state: "ready", reason: String?.none),
            (id: "flatone", name: "flatone", ready: true, state: "ready", reason: String?.none),
        ]
        let capabilities: [String: Set<String>] = [
            "serieshub": ["staffeln", "suche"],
            "animehub": ["staffeln", "suche"],
            "flatone": ["aufloeser"],
        ]

        let searchable = PortalSearchSource.searchablePortals(portals, capabilities: capabilities)

        #expect(searchable.count == 2)
        #expect(!searchable.contains { $0.id == "flatone" })
        #expect(
            PortalSearchSource.footer(ready: 2, total: searchable.count)
                == PortalSearchSource.footer(ready: 2, total: 2),
            "two of two is not a fraction — before, this said two of three")
    }

    /// **An unknown portal counts too, and that is the more harmless direction.**
    /// Calculated out, it would hide a real outage.
    @Test("If the bridge reports no capabilities, nothing is excluded")
    func unknownCapabilityCountsToo() {
        let portals = [
            (id: "neu", name: "New", ready: false, state: "broken", reason: String?.some("login"))
        ]

        #expect(PortalSearchSource.searchablePortals(portals, capabilities: [:]).count == 1)
    }
}

/// A search source that does not search.
private struct TrialSearch: SearchSource {
    let origin: Catalog.Origin
    let match: [Match]
    var hasAnswered = true
    var delay: Duration = .zero

    func match(zu word: String, atMost: Int) async -> ResultBundle {
        if delay > .zero { try? await Task.sleep(for: delay) }
        return ResultBundle(
            origin: origin, headline: .wording(origin.rawValue),
            match: match, hasAnswered: hasAnswered)
    }
}

/// **The phone search runs the shared flow** (AP58 R6, St4) — the checks that
/// must go red there against a falsified rule.
@Suite("Search — shared flow")
struct SearchFlowPhoneTests {

    @Test("If no source answers it is a failure and not \"nothing found\"")
    @MainActor
    func allSilent() async {
        let model = SearchViewModel(
            debounce: .zero,
            sources: [
                TrialSearch(origin: .jellyfin, match: [], hasAnswered: false),
                TrialSearch(origin: .portals, match: [], hasAnswered: false),
            ])
        model.word = "drugladan"
        await model.running?.value
        guard case .disrupted = model.state else {
            Issue.record("expected: failure, was \(model.state)")
            return
        }
    }

    @Test("Waiting time and match count are the shared ones")
    @MainActor
    func limits() {
        #expect(SearchViewModel.waitTime == .milliseconds(350))
        #expect(SearchViewModel.perGroup == 20)
    }
}
