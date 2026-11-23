import Core
import Foundation
import ParentalControls
import Testing

@testable import FeaturesPhone

/// **The phone reads the profile's limit** — tvOS roadmap AP45, 2026-09-24.
///
/// Up to here the rule took only the device base. On the TV the stricter of profile and
/// device applied to the same child profile, here the wider.
@MainActor
@Suite("The profile limit on the phone")
struct ProfileLimitTests {

    private func state(_ keychain: InMemoryStore) -> ParentalControlsState {
        ParentalControlsState(
            store: UserDefaults(suiteName: UUID().uuidString)!, keychain: keychain)
    }

    /// **The connection:** The rule by which filtering happens carries the limit of the
    /// active child profile — not just the base.
    @Test("The rule carries the stricter limit of the active profile")
    func ruleCarriesProfileLimit() {
        let keychain = InMemoryStore()
        AgeLimit.write(.from12, in: keychain)
        AgeLimit.write(.from6, in: keychain, forItem: "profile-a")
        let state = state(keychain)
        ProfilePointer.als("profile-a") { #expect(state.rule.limit == .from6) }
        ProfilePointer.als(nil) { #expect(state.rule.limit == .from12) }
    }

    /// **A looser profile limit does not lift the base** — otherwise the profile would be
    /// a way around the device's parental controls.
    @Test("A looser profile limit opens nothing")
    func looserOpensNothing() {
        let keychain = InMemoryStore()
        AgeLimit.write(.from12, in: keychain)
        AgeLimit.write(.from16, in: keychain, forItem: "profile-a")
        let state = state(keychain)
        ProfilePointer.als("profile-a") { #expect(state.rule.limit == .from12) }
    }

    /// **If the profile changes, the limit changes** — the remembered value belongs to one
    /// ID and must not stick to the next profile.
    @Test("After a profile switch the limit of the new profile applies")
    func switchRereads() {
        let keychain = InMemoryStore()
        AgeLimit.write(.from6, in: keychain, forItem: "profile-a")
        AgeLimit.write(.from12, in: keychain, forItem: "profile-b")
        let state = state(keychain)
        ProfilePointer.als("profile-a") { #expect(state.rule.limit == .from6) }
        ProfilePointer.als("profile-b") { #expect(state.rule.limit == .from12) }
    }
}
