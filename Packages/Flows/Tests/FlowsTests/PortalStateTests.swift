import Flows
import PortalKit
import Testing

/// **The portal state arises from the state word, not from the reason text** (audit
/// 2026-09-27, Portals B2).
///
/// Counter-check: with the old construction `PortalState(row.reason ?? "", reason: row.reason)` in
/// ``Flows/PortalState/init(_:)-(PortalRow)`` ``withoutReason(word:expected:)``
/// and ``selectable()`` turn red.
@Suite("Portal state from the portal row")
struct PortalStateTests {

    static func row(_ word: String, reason: String? = nil) -> PortalRow {
        PortalRow(
            id: "p", name: "P", ready: word == "ready", state: word, reason: reason)
    }

    @Test(
        "The state word holds even without a reason",
        arguments: [
            ("needs_setting", PortalState.needsSetting),
            ("needs_login", .muted),
            ("anmeldung_noetig", .login),
            ("ready", .ready),
            ("broken", .muted),
            ("disabled", .muted),
        ])
    func withoutReason(word: String, expected: PortalState) {
        #expect(PortalState(Self.row(word)) == expected)
    }

    @Test("A missing setting without reason text stays selectable")
    func selectable() {
        #expect(PortalState(Self.row("needs_setting")).isSelectable)
    }

    /// Server words with a reason: the reason is shown verbatim, the portal stays selectable.
    @Test("Broken or switched off with a reason is passed through verbatim")
    func withReason() {
        let broken = PortalState(Self.row("broken", reason: "Quelle antwortet nicht"))
        #expect(broken == .other("Quelle antwortet nicht"))
        #expect(broken.isSelectable)
        #expect(
            PortalState(Self.row("needs_setting", reason: "setting required but empty: key"))
                == .needsSetting)
    }

    /// The reason text is never the state word — a reason that happens to be called
    /// "needs_setting" does not turn a broken portal into a missing setting.
    @Test("The reason text is not read as a state word")
    func reasonIsNotAWord() {
        #expect(PortalState(Self.row("broken", reason: "needs_setting")) == .other("needs_setting"))
    }

    @Test("A row without an explicit word defaults to ready")
    func preset() {
        #expect(PortalRow(id: "p", name: "P").state == "ready")
        #expect(PortalRow(id: "p", name: "P", ready: false).state.isEmpty)
    }
}
