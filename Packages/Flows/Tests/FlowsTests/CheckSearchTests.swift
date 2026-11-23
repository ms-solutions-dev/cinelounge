import Core
import Flows
import Foundation
import Testing

/// Audit finding S1: a silent source next to empty answers yields "nothing found".
@MainActor
struct CheckSearchTests {

    struct Group: SearchGroup {
        var source: Origin
        var count: Int
        var hasAnswered = true
        var hasMatches: Bool { count > 0 }
        var logLine: String { "\(source.rawValue) \(count)" }
    }

    @Test("Media server silent, provider empty: no claim of \"nothing found\"")
    func silentAndEmpty() async {
        let search = Search<Group>(
            sources: [
                { _, _ in Group(source: .jellyfin, count: 0, hasAnswered: false) },
                { _, _ in Group(source: .provider, count: 0) },
            ], debounce: .zero)
        search.word = "lattice"
        await search.running?.value
        // The silent group is in `groups`, but the situation says "nothing found" —
        // both views then show the empty screen and not the failure.
        #expect(search.state != .nothingFound)
    }
}
