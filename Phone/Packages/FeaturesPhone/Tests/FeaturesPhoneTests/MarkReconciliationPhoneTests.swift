import SourceProbe
import Testing

/// **The wiring of the brand match on the phone** — tvOS roadmap AP47, 2026-09-25.
///
/// The match itself has been in the `Household` package since AP58 R2 and is checked there for both
/// programs (`BrandMatchingTests`, including the phone signed in by PIN). What remains
/// here is who calls it on the phone.
@Suite("Reconciling marks on the phone — wiring")
struct MarkReconciliationPhoneTests {

    /// **The connections:** Sign-in state, ending sharing and removing call the match.
    @Test("Portal settings and sharing call the mark reconciliation")
    func wiring() throws {
        func text(_ name: String) throws -> String {
            try SourceText.read(name, in: .featuresPhone)
                .split(separator: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
        }
        let portals = try text("PortalSettingsView.swift")
        #expect(
            portals.contains("TokenReconciliation.onDevice()?.reconcile(me: me, isBorrowed: isBorrowed)"))
        // **Ending sharing and removing revoke via the shared flow** (AP58 R2).
        let cloud = try text("CloudView.swift")
        #expect(cloud.contains("pullMode: .camera)"))
        #expect(!cloud.contains("revoke:"), "a separate revocation bypassing the flow")
        #expect(!cloud.contains("cloud.endSharing("), "ending sharing bypassing the flow")
    }
}
