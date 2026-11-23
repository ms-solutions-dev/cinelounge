import Core
import Downloads
import Foundation
import NetworkStatus
import ParentalControls
import ProfileKit
import SourceProbe
import Testing

@testable import FeaturesPhone

/// **The phone computes parental controls from profile and device** — tvOS roadmap AP45,
/// row "The phone does not read the profile limit", 2026-09-25.
///
/// Since 2026-09-24 it has read the limit from both (``ProfileLimitTests``); lock, board and
/// kind still came from the device alone. This test checks the **rule** that every view
/// asks, not the helper values underneath.
@MainActor
@Suite("Child profile on the phone")
struct ChildProfilePhoneTests {

    private func state(
        _ bundle: InMemoryStore, ledger: InMemoryStore? = nil
    ) -> ParentalControlsState {
        ParentalControlsState(
            store: UserDefaults(suiteName: UUID().uuidString)!, keychain: bundle,
            ledgerStore: ledger)
    }

    // MARK: - Unverstandenes sperren: eines von beiden sperrt

    @Test("If the profile locks, the rule locks — even if the device does not")
    func profileLocks() {
        let bundle = InMemoryStore()
        UnrecognizedLock.write(false, in: bundle)
        UnrecognizedLock.write(true, in: bundle, forItem: "child")
        let state = state(bundle)
        ProfilePointer.als("child") { #expect(state.rule.blocksUnrecognized) }
        ProfilePointer.als(nil) { #expect(!state.rule.blocksUnrecognized) }
    }

    @Test("If the device locks, a profile does not lift the lock")
    func deviceLocks() {
        let bundle = InMemoryStore()
        UnrecognizedLock.write(true, in: bundle)
        UnrecognizedLock.write(false, in: bundle, forItem: "child")
        let state = state(bundle)
        ProfilePointer.als("child") { #expect(state.rule.blocksUnrecognized) }
    }

    @Test("If neither locks, the rule does not lock")
    func noneLocks() {
        let bundle = InMemoryStore()
        UnrecognizedLock.write(false, in: bundle)
        UnrecognizedLock.write(false, in: bundle, forItem: "child")
        let state = state(bundle)
        ProfilePointer.als("child") { #expect(!state.rule.blocksUnrecognized) }
    }

    /// **The finding from track G** (2026-09-25): A profile without an entry read as
    /// "yes", and the device switch "off" never took effect as soon as a profile was active.
    @Test("Device off and profile without an entry does not lock")
    func profileWithoutEntryStaysSilent() {
        let bundle = InMemoryStore()
        UnrecognizedLock.write(false, in: bundle)
        let state = state(bundle)
        ProfilePointer.als("child") {
            #expect(!state.rule.blocksUnrecognized)
        }
    }

    /// **The device keeps the cautious default** — there, "nothing set" means
    /// undecided, and undecided locks.
    @Test("A device without an entry locks, even with a profile without an entry")
    func deviceWithoutEntryLocks() {
        let state = state(InMemoryStore())
        ProfilePointer.als("child") { #expect(state.rule.blocksUnrecognized) }
        ProfilePointer.als(nil) { #expect(state.rule.blocksUnrecognized) }
    }

    // MARK: - Assignments: both boards, the profile has the last word

    @Test("The assignments of both boards apply, the profile overrides the device")
    func assignmentsCombined() {
        let bundle = InMemoryStore()
        UnrecognizedRatings(assignments: ["TV-MA": 16, "R": 16]).save(to: bundle)
        UnrecognizedRatings(assignments: ["TV-MA": 12, "NR": 6]).save(to: bundle, forItem: "child")
        let state = state(bundle)
        ProfilePointer.als("child") {
            #expect(state.rule.assignments == ["TV-MA": 12, "R": 16, "NR": 6])
        }
        ProfilePointer.als(nil) { #expect(state.rule.assignments == ["TV-MA": 16, "R": 16]) }
    }

    // MARK: - Kontoart: Kinderprofil oder Kinderkonto

    private func ledger(using profileEntry: [Profile]) -> InMemoryStore {
        let store = InMemoryStore()
        var ledger = ProfileBook()
        for profileName in profileEntry { ledger.create(profileName) }
        ledger.write(in: store)
        return store
    }

    @Test("A child profile is a child — even without a child account")
    func childProfileIsChild() {
        let kind = Profile(identifier: .init(rawValue: "k-child"), name: "Child", kind: .kind)
        let parents = Profile(identifier: .init(rawValue: "k-parent"), name: "Parent")
        let state = state(InMemoryStore(), ledger: ledger(using: [kind, parents]))
        state.accountKind = .adult
        ProfilePointer.als("k-child") { #expect(state.rule.accountKind == .kind) }
        ProfilePointer.als("k-parent") { #expect(state.rule.accountKind == .adult) }
    }

    @Test("A child account of the old list stays a child — OR, not instead")
    func childAccountStays() {
        let parents = Profile(identifier: .init(rawValue: "k-parent"), name: "Parent")
        let state = state(InMemoryStore(), ledger: ledger(using: [parents]))
        state.accountKind = .kind
        ProfilePointer.als("k-parent") { #expect(state.rule.accountKind == .kind) }
    }

    /// **Recompute after a change to the ledger:** Another device turns the profile into a
    /// child profile; without ``ParentalControlsState/rereadProfile()`` the remembered state would stay.
    @Test("After liesProfilNeu the profile's new kind applies")
    func reread() {
        let person = Profile(identifier: .init(rawValue: "k-child"), name: "Child")
        let store = ledger(using: [person])
        let state = state(InMemoryStore(), ledger: store)
        ProfilePointer.als("k-child") {
            #expect(state.rule.accountKind == .adult)
            var ledger = ProfileBook.read(from: store)
            ledger.update(person.identifier) { $0.kind = .kind }
            ledger.write(in: store)
            state.rereadProfile()
            #expect(state.rule.accountKind == .kind)
        }
    }

    // MARK: - The account switch is a profile switch

    /// **The connection that was missing:** The account switch only switched the session.
    /// ``ProfileKit/ProfileSwitch/episode(account:ledgerStore:keychain:pinStore:deviceStore:pin:)``
    /// switches ledger, pointer and session to the account's profile.
    @Test("An account switch sets ledger and pointer to the account's profile")
    func accountSwitchFollows() {
        let server = URL(string: "https://jellyfin.example")!
        let kind = Profile(
            identifier: .init(rawValue: "k-child"), name: "Child", kind: .kind,
            credentials: [.jellyfin(server: server, userID: "u-child", username: "Child")])
        let parents = Profile(
            identifier: .init(rawValue: "k-parent"), name: "Parent",
            credentials: [.jellyfin(server: server, userID: "u-parent", username: "Parent")])
        let store = ledger(using: [parents, kind])
        var ledger = ProfileBook.read(from: store)
        ledger.switchTo(zu: parents.identifier)
        ledger.write(in: store)

        let session = SecureStore(service: "probe.\(UUID().uuidString)")
        let account = Account.Identifier(server: server.absoluteString, user: "u-child").stored
        ProfilePointer.als("k-parent") {
            let switched = ProfileSwitch.episode(
                account: account, ledgerStore: store, keychain: session,
                pinStore: InMemoryStore(), deviceStore: InMemoryStore(), pin: nil)
            #expect(switched.result?.profile == kind)
            #expect(ProfilePointer.active == "k-child")
            #expect(ProfileBook.read(from: store).active == kind.identifier)
            // And the same switch once more does nothing.
            #expect(
                ProfileSwitch.episode(
                    account: account, ledgerStore: store, keychain: session,
                    pinStore: InMemoryStore(), deviceStore: InMemoryStore(), pin: nil)
                    == .unchanged)
        }
    }

    // MARK: - Downloads in child mode

    private var childRule: ProtectionRule {
        ProtectionRule(
            deviceLocked: true, accountKind: .kind, isPinSet: true, limit: nil,
            blocksUnrecognized: true, assignments: [:])
    }

    @Test("Downloads show a child no portal and provider titles")
    func downloadsFiltered() {
        let portal = DownloadJob(
            id: .init("serieshub|morrowfeld-1-1|https://serieshub.example/redirect/1"), title: "Portal",
            beside: nil, source: .portal, extent: .film, tier: .low,
            estimatedSize: 1_000)
        let own = DownloadJob(
            id: .init("8dec87ad"), title: "Own", beside: nil, source: .jellyfin,
            extent: .film, tier: .low, estimatedSize: 1_000)
        let model = DownloadsModel(networkMonitor: NetworkStatus.NetworkWatch(), rule: childRule)
        model.set(
            downloads: Downloads(items: [portal, own], isRunning: []),
            household: StorageBudget(items: [], unrestricted: 1_000_000), durations: [:], seen: [])
        #expect(model.rows(forItem: .everything).map(\.title) == ["Own"])

        let pending = DownloadsModel(networkMonitor: NetworkStatus.NetworkWatch(), rule: .pending)
        pending.set(
            downloads: Downloads(items: [portal, own], isRunning: []),
            household: StorageBudget(items: [], unrestricted: 1_000_000), durations: [:], seen: [])
        #expect(pending.rows(forItem: .everything).count == 2)
    }

    // MARK: - The connections in the shell

    /// The source text without pure comment lines, as one string.
    private static func code(_ name: String) throws -> String {
        try SourceText.read(name, in: .featuresPhone)
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// The body of a function — **up to the next declaration**, not just the next
    /// 260 characters: Since AP52 the latch sits in ``ShellModel`` before the profile switch, and
    /// a fixed excerpt would cut off the call being looked for.
    static func bodyContent(_ beginning: String, in text: String) -> Substring {
        guard let startValue = text.range(of: beginning) else { return "" }
        let rest = text[startValue.upperBound...]
        let end =
            ["\n    private func ", "\n    public func ", "\n    func "]
            .compactMap { rest.range(of: $0)?.lowerBound }
            .min() ?? rest.endIndex
        return rest[..<end]
    }

    /// What hangs on a call — the next characters after each occurrence.
    private static func callCount(_ character: String, in text: String) -> [Substring] {
        text.ranges(of: character).map { text[$0.lowerBound...].prefix(260) }
    }

    /// **The locks above only help if the wrapper passes the rule in.** Player and
    /// downloads got none until today; a forgotten `rule:` would fall back to the default
    /// `.pending` and look exactly as before.
    ///
    /// **Since the H8 wrapper check, the downloads get the parental controls themselves** and read
    /// the rule on every draw — one copied at construction stayed in the `@State`.
    @Test("Player and downloads receive the parental-controls rule")
    func shellPassesRule() throws {
        let text = try Self.code("TabPlaceholder.swift")
        let player = Self.callCount("SourceAssembly.playerSource(", in: text)
        let downloads = Self.callCount("DownloadsModel(", in: text)
        #expect(!player.isEmpty && !downloads.isEmpty)
        for call in player {
            #expect(call.contains("rule: model.parentalControls.rule"), "\(call.prefix(60))")
        }
        for call in downloads {
            #expect(call.contains("parentalControls: model.parentalControls)"), "\(call.prefix(60))")
        }
    }

    /// **The account switch follows with the profile, and the switch recomputes.**
    @Test("Account switch and pointer switch are wired in the shell")
    func shellFollowsProfile() throws {
        let model = try Self.code("ShellModel.swift")
        let switchObserver = Self.bodyContent("private func adoptAccount(", in: model)
        #expect(switchObserver.contains("ProfileSwitch.episode("))
        let view = try Self.code("ShellView.swift")
        #expect(view.contains("publisher(for: ProfilePointer.switched)"))
        #expect(
            Self.callCount("publisher(for: ProfilePointer.switched)", in: view).first?
                .contains("model.profileSwitched()") == true)
    }

    /// **The wrapper re-reads anything that arrived remotely** (TV finding C2-5, track E).
    @Test("Profilwolke.angekommen makes parental controls and header image reread")
    func cloudArrived() throws {
        let view = try Self.code("ShellView.swift")
        #expect(
            Self.callCount("publisher(for: ProfileCloud.arrived)", in: view).first?
                .contains("model.cloudArrived()") == true)
        let model = try Self.code("ShellModel.swift")
        let bodyContent = Self.callCount("public func cloudArrived()", in: model).first ?? ""
        #expect(bodyContent.contains("parentalControls.rereadProfile()"))
        #expect(bodyContent.contains("profileImages.load()"))
    }

    /// **N-1 from track E:** An account leads only to **its own** profile — never to one without a
    /// media server, whose name would then sit above the previous account's session.
    @Test("An account without its own profile does not switch the profile")
    func noSwitchWithoutJellyfin() {
        let listOnly = Profile(identifier: .init(rawValue: "k-list"), name: "List")
        let store = ledger(using: [listOnly])
        ProfilePointer.als("k-other") {
            #expect(
                ProfileSwitch.episode(
                    account: Account.Identifier(server: "https://x.example", user: "u").stored,
                    ledgerStore: store,
                    keychain: SecureStore(service: "probe.\(UUID().uuidString)"),
                    pinStore: InMemoryStore(), deviceStore: InMemoryStore(), pin: nil)
                    == .unknown)
            #expect(ProfilePointer.active == "k-other")
        }
    }
}
