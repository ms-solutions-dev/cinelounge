import SourceProbe
import Testing

/// **The wiring of the brand match on the TV** (AP47, 2026-09-25).
///
/// The match itself has stood in the `Household` package since AP58 R2 and is checked there for both
/// programs (`BrandMatchingTests`). What remains here is **who** calls it — without these
/// places everything would be built there and never run.
@Suite("Updating the brand — wiring on the TV")
struct BrandMatchingTests {

    /// The wiring: Settings, sidebar and ending sharing (through
    /// `SharingFlow`) call the match. Without these places everything above would be built and never run.
    @Test("Wiring: three callers")
    func wiring() throws {
        func text(_ name: String) throws -> String {
            try SourceText.read(name, in: .features)
        }
        #expect(
            try text("PortalSettings.swift").contains("TokenReconciliation.onDevice()?.reconcile(me:"))
        #expect(try text("MainView.swift").contains("TokenReconciliation.onDevice()?.reconcile()"))
        // **Sharing revokes through the shared flow** (AP58 R2): the revocation lives in
        // `SharingFlow` (default `TokenReconciliation.onDevice()`), the sheet does not pass in its
        // own.
        let sheet = try text("CloudSheet.swift")
        #expect(sheet.contains("SharingFlow(profile: profile, cloud: cloud, pullMode: .code)"))
        #expect(!sheet.contains("revoke:"), "a separate revoke bypassing the flow")
        #expect(!sheet.contains("cloud.endSharing("), "ending sharing bypassing the flow")
    }
}
