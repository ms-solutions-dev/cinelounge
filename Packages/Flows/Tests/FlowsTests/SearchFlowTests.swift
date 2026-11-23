import Core
import Flows
import Foundation
import Testing

/// **The one search flow** (AP58 R6, St4) — with sources made of rows, without a platform.
@MainActor
struct SearchFlowTests {

    struct Group: SearchGroup {
        var source: Origin
        var count: Int
        var hasAnswered = true
        var hasMatches: Bool { count > 0 }
        var logLine: String { "\(source.rawValue) \(count)" }
    }

    static func source(
        _ origin: Origin, _ count: Int, responds: Bool = true
    )
        -> Search<Group>.Source
    {
        { _, _ in Group(source: origin, count: count, hasAnswered: responds) }
    }

    static func needle(_ search: Search<Group>, _ word: String) async {
        search.word = word
        await search.running?.value
    }

    @Test("A silent group stays, an empty one goes, the order is that of the sources")
    func silentStays() async {
        let search = Search<Group>(
            sources: [
                Self.source(.jellyfin, 0, responds: false), Self.source(.provider, 0),
                Self.source(.portals, 2),
            ], debounce: .zero)
        await Self.needle(search, "ez")
        #expect(search.groups.map(\.source) == [.jellyfin, .portals])
        #expect(search.state == .settled)
    }

    @Test("If nobody answers, it is a disruption with the platform's no-network state")
    func allSilent() async {
        let search = Search<Group>(
            sources: [Self.source(.provider, 0, responds: false)], debounce: .zero,
            offline: { .noConnection })
        await Self.needle(search, "ez")
        #expect(search.state == .disrupted(.noConnection))
    }

    @Test("One character is idle, clearing leads back")
    func idle() async {
        let search = Search<Group>(sources: [Self.source(.jellyfin, 1)], debounce: .zero)
        search.word = "e"
        #expect(search.state == .idle)
        await Self.needle(search, "ez")
        #expect(search.state == .settled)
        search.clear()
        #expect(search.state == .idle)
        #expect(search.groups.isEmpty)
    }
}
