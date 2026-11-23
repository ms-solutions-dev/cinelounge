import Foundation
import Testing

@testable import Core

/// **Test Apple TV, 2026-09-28:** just watched "Marder vs. Mainspring", and in "Continue Watching"
/// it stood further back — the row chained the sources one after another.
@Suite("Continue Watching: most recently watched first, regardless of origin")
struct ContinueWatchingOrderTests {

    private struct Title { let id: String; let when: Date? }
    private let now = Date()

    @Test("The title just watched comes first, even if its source came last")
    func justWatched() {
        let channels = [Title(id: "sender", when: now.addingTimeInterval(-3600))]
        let jellyfin = [Title(id: "coyote", when: now.addingTimeInterval(-60))]
        let cl = [Title(id: "zinne", when: now.addingTimeInterval(-600))]
        let row = ContinueWatching.mix(
            [channels, jellyfin, cl], identifier: \.id, recent: \.when)
        #expect(row.map(\.id) == ["coyote", "zinne", "sender"])
    }

    @Test("Without a timestamp to the back, there in source order")
    func withoutTimestamp() {
        let row = ContinueWatching.arrange(
            [Title(id: "a", when: nil), Title(id: "b", when: now), Title(id: "c", when: nil)],
            recent: \.when)
        #expect(row.map(\.id) == ["b", "a", "c"])
    }

    @Test("Without ordering info the old order stays")
    func withoutOrder() {
        let row = ContinueWatching.mix(
            [[Title(id: "a", when: nil)], [Title(id: "b", when: now)]], identifier: \.id)
        #expect(row.map(\.id) == ["a", "b"])
    }

    /// 2026-09-29: TV and phone hand in the same entries in a different order
    /// (channels first on the TV, by source on the phone) — the row must be the same.
    @Test("Same entries, different source order — same row")
    func tie() {
        struct E: Equatable { let id: String; let when: Date? }
        func e(_ id: String, _ s: TimeInterval) -> E { E(id: id, when: Date(timeIntervalSince1970: s)) }
        let channels = [e("a-haber", 4000), e("telve-1", 2500)]
        let jellyfin = [e("clock-ward", 1000), e("ember-warden", 900)]
        let clServer = [e("osaka-ledger", 3000)]
        let tv = ContinueWatching.mix([channels, jellyfin + clServer], identifier: \.id, recent: \.when)
        let phone = ContinueWatching.mix([jellyfin + channels + clServer], identifier: \.id, recent: \.when)
        #expect(tv.map(\.id) == ["a-haber", "osaka-ledger", "telve-1", "clock-ward", "ember-warden"])
        #expect(phone.map(\.id) == tv.map(\.id))
    }
}
