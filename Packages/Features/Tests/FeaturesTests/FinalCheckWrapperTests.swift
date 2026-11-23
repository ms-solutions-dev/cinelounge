import Core
import Foundation
import ParentalControls
import ProfileKit
import Testing

@testable import Features

/// **The findings of the final check of 2026-09-25 on the shell** (track E) — each via
/// the calculation that decides in the app: ``AccountSwitcher/session(after:load:)`` for
/// the session after a switch (N-1), ``LanguageDeferral`` for the rebuild after a
/// language change (B-1), ``ChildGuard/target(afterDiscarding:surface:)`` for the
/// target after a changed rule (A2-1) and ``ChildGuard/notifications`` for what comes from
/// remote (C2-5).
@MainActor
@Suite("Final check: wrapper")
struct FinalCheckWrapperTests {

    // MARK: - N-1

    @Test("N-1: Without a switched session the switcher passes none on, not even a standing one")
    func noForeignSession() throws {
        try ProfilePointer.als(nil) {
            let address = URL(string: "https://jf.example")!
            let parentCredentials = ServerCredentials(
                serverURL: address, userID: "papa", username: "Papa", accessToken: "m")
            let sharedStore = SecureStore(service: "abschluss.\(UUID().uuidString)")
            defer { try? sharedStore.clearCredentials() }
            try sharedStore.memorize(parentCredentials)
            try sharedStore.switchTo(server: address, user: "papa")
            var papa = Profile(name: "Papa")
            papa.create(.jellyfin(server: address, userID: "papa", username: "Papa"))
            let childProfile = Profile(name: "Selin", kind: .kind)
            var ledger = ProfileBook()
            ledger.create(papa)
            ledger.create(childProfile)
            ledger.switchTo(zu: papa.identifier)

            let toChild = ProfileSwitch.switchTo(
                zu: childProfile.identifier, in: &ledger, keychain: sharedStore,
                deviceStore: InMemoryStore(), ledgerStore: InMemoryStore()
            ).result
            // Even if something were still in the Keychain: It does not go out.
            #expect(AccountSwitcher.session(after: toChild, load: { parentCredentials }) == nil)

            let toPapa = ProfileSwitch.switchTo(
                zu: papa.identifier, in: &ledger, keychain: sharedStore,
                deviceStore: InMemoryStore(), ledgerStore: InMemoryStore()
            ).result
            #expect(
                AccountSwitcher.session(after: toPapa, load: { try? sharedStore.loadCredentials() })?.userID
                    == "papa")
        }
    }

    // MARK: - B-1

    @Test("B-1: As long as a film plays the identifier stays — afterwards it is rebuilt")
    func deferralDuringMovie() {
        var deferral = LanguageDeferral()
        #expect(deferral.identifier(current: "de") == "de")

        // A language arrives from remote while the player is open.
        deferral.switchObserver(from: "de", isBlocked: true)
        #expect(deferral.identifier(current: "tr") == "de", "the player would be torn down")
        // A second change, still during the movie: The first one stays in place.
        deferral.switchObserver(from: "tr", isBlocked: true)
        #expect(deferral.identifier(current: "en") == "de")
        deferral.verify(isBlocked: true)
        #expect(deferral.waiting)

        // The movie is closed.
        deferral.verify(isBlocked: false)
        #expect(!deferral.waiting)
        #expect(deferral.identifier(current: "en") == "en")
    }

    @Test("B-1: Without a sheet a switch applies immediately")
    func withoutSheetImmediately() {
        var deferral = LanguageDeferral()
        deferral.switchObserver(from: "de", isBlocked: false)
        #expect(deferral.identifier(current: "tr") == "tr")
        #expect(!deferral.waiting)
    }

    // MARK: - A2-1

    @Test("A2-1: After a change of the rule \"Live\" stays Live")
    func liveStaysLive() {
        let pending = ProtectionRule.pending
        let kind = ProtectionRule(deviceLocked: false, accountKind: .kind, isPinSet: false)
        #expect(ChildGuard.target(afterDiscarding: .live, rule: pending) == .live)
        #expect(ChildGuard.target(afterDiscarding: .favorites, rule: kind) == .favorites)
        // What a child cannot reach leads on to the media library — Live without an allow list.
        #expect(ChildGuard.target(afterDiscarding: .live, rule: kind) == .media)
        #expect(ChildGuard.target(afterDiscarding: .settings, rule: kind) == .media)
    }

    // MARK: - C2-5

    @Test("C2-5: The guard listens to the pointer and to remote arrivals")
    func guardListensRemotely() {
        #expect(Set(ChildGuard.notifications) == [ProfilePointer.switched, ProfileCloud.arrived])
    }
}
