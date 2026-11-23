import Core
import Flows
import Foundation
import ParentalControls
import ProfileKit
import SourceProbe
import Testing

@testable import FeaturesPhone

/// **"Who's watching?" on the phone shows profiles, as on the TV** (G3, findings B1, B2,
/// B3, C10; decisions 3, 20, 25).
///
/// What is tested is **across the connection**: the wrapper with an injected shared
/// ``Flows/ProfileManagement`` (ledger in memory, its own Keychain), the same door
/// `accountSwitch` and the same profile-PIN latch as on the TV.
@MainActor
@Suite("Who is watching? on the phone")
struct WhoIsWatchingPhoneTests {

    /// A household with an adult profile (adult, no media server) and a child profile
    /// (child, with nothing).
    @MainActor
    struct Household {
        let ledger = InMemoryStore()
        let device = InMemoryStore()
        let keychain = SecureStore(service: "probe.\(UUID().uuidString)")
        let parent: Profile.Identifier
        let childProfile: Profile.Identifier
        let administration: ProfileManagement

        init() {
            administration = ProfileManagement(
                keychain: keychain, store: ledger, cloud: { nil },
                startStore: UserDefaults(suiteName: "probe.\(UUID().uuidString)")!)
            parent = administration.create(name: "Parent", color: .turquoise, kind: .adult, avatar: nil)!
            childProfile = administration.create(name: "Sam", color: .moss, kind: .kind, avatar: nil)!
        }

        func profile(_ identifier: Profile.Identifier) -> Profile {
            administration.profile.first { $0.identifier == identifier }!
        }

        /// The wrapper of this household — **parental controls and management read the same
        /// ledger.**
        func wrapper(devicePin: Bool = false, locked: Bool = false) -> ShellModel {
            if devicePin { _ = Pin(store: device).set("1234") }
            let state = ParentalControlsState(
                store: UserDefaults(suiteName: UUID().uuidString)!, keychain: device,
                ledgerStore: ledger)
            if locked { state.mode.set(true) }
            return ShellModel(parentalControls: state, profile: administration)
        }

        func cleanUp() {
            ProfilePIN(store: keychain, forItem: parent).forget()
            try? keychain.clearCredentials()
        }
    }

    // MARK: - B2 · Profile statt Konten

    @Test("A profile without media server access is selectable")
    func selectableWithoutAccess() {
        let household = Household()
        defer { household.cleanUp() }
        ProfilePointer.als(nil) {
            #expect(household.administration.switchTo(zu: household.parent).result != nil)
            let wrapper = household.wrapper()
            wrapper.switchProfile(household.profile(household.childProfile))
            #expect(wrapper.profile.active == household.childProfile)
            #expect(ProfilePointer.active == household.childProfile.rawValue)
            #expect(wrapper.surface == .kind, "the child interface follows the profile")
            #expect(!wrapper.isManageable, "and management drops out (decision 20)")
        }
    }

    @Test("With profile PIN: the latch opens, a wrong PIN switches nothing")
    func lock() {
        let household = Household()
        defer { household.cleanUp() }
        ProfilePointer.als(nil) {
            #expect(
                ProfilePINMaintenance.set(
                    "4711", old: nil, forItem: household.parent, keychain: household.keychain, cloud: nil,
                    now: Date()) == .isSet)
            #expect(household.administration.switchTo(zu: household.childProfile).result != nil)
            let wrapper = household.wrapper()
            wrapper.switchProfile(household.profile(household.parent))
            #expect(
                wrapper.profilePinState == .lock(account: nil, profile: household.profile(household.parent)))
            #expect(
                wrapper.profile.active == household.childProfile, "nothing switches in front of the latch")

            #expect(!wrapper.openLatch("0000"))
            #expect(wrapper.profile.active == household.childProfile)
            #expect(ProfilePointer.active == household.childProfile.rawValue)

            #expect(wrapper.openLatch("4711"))
            #expect(wrapper.profile.active == household.parent)
            #expect(wrapper.profilePinState == nil)
        }
    }

    @Test("A child with a device PIN first stands at the “kontowechsel” door")
    func doorBeforeSwitch() {
        let household = Household()
        defer { household.cleanUp() }
        ProfilePointer.als(nil) {
            #expect(household.administration.switchTo(zu: household.childProfile).result != nil)
            let wrapper = household.wrapper(devicePin: true)
            #expect(wrapper.parentalControls.rule.applies)
            wrapper.switchProfile(household.profile(household.parent))
            #expect(
                wrapper.navigator.waiting
                    == .door(
                        identifier: "kontowechsel",
                        reason: LockedDoors.reason("kontowechsel") ?? ""))
            #expect(wrapper.profile.active == household.childProfile, "nothing switches behind the door")

            if let job = wrapper.navigator.waiting {
                #expect(!wrapper.parentalControls.verify("0000", forItem: job))
                #expect(wrapper.parentalControls.verify("1234", forItem: job))
            }
            wrapper.navigator.letPass()
            #expect(wrapper.profile.active == household.parent)
        }
    }

    @Test("Tapping your own profile does nothing")
    func own() {
        let household = Household()
        defer { household.cleanUp() }
        ProfilePointer.als(nil) {
            #expect(household.administration.switchTo(zu: household.parent).result != nil)
            let wrapper = household.wrapper(devicePin: true, locked: true)
            wrapper.switchProfile(household.profile(household.parent))
            #expect(wrapper.navigator.waiting == nil, "no door for a switch that is not one")
            #expect(wrapper.profilePinState == nil)
        }
    }

    // MARK: - B1 · Anlegen und Verwalten

    /// **Observed on the sheet:** For an adult the person sheet closes (afterwards the view
    /// opens through ``SheetState/close(following:)``); for a child everything stays as it
    /// was — the button does nothing.
    @Test("Creating and managing are open to adults, not to a child")
    func actions() {
        let household = Household()
        defer { household.cleanUp() }
        ProfilePointer.als(household.parent.rawValue) {
            let wrapper = household.wrapper()
            #expect(wrapper.isManageable)
            for mutate in [wrapper.createProfile, wrapper.manageProfiles, wrapper.addCredentials] {
                wrapper.sheetState.open(.accountSwitch)
                mutate()
                #expect(wrapper.sheetState.pending == nil, "the sheet closes, the view follows")
            }
        }
        ProfilePointer.als(household.childProfile.rawValue) {
            let wrapper = household.wrapper()
            #expect(!wrapper.isManageable)
            for mutate in [wrapper.createProfile, wrapper.manageProfiles, wrapper.addCredentials] {
                wrapper.sheetState.open(.accountSwitch)
                mutate()
                #expect(wrapper.sheetState.pending == .accountSwitch, "for a child the button does nothing")
            }
            wrapper.navigator.show(.profile)
            wrapper.navigator.show(.profileChanged)
            #expect(wrapper.navigator.overlay.isEmpty, "not even via a jump")
            #expect(wrapper.navigator.waiting == nil, "and without a door in front")
        }
    }

    @Test("An adult on a locked device needs the device PIN for the profiles")
    func doorForAdults() {
        let household = Household()
        defer { household.cleanUp() }
        ProfilePointer.als(household.parent.rawValue) {
            let wrapper = household.wrapper(devicePin: true, locked: true)
            #expect(wrapper.isManageable)
            #expect(wrapper.surface == .familiar, "the device lock is not a child interface")
            for view in [ViewID.profile, .profileChanged] {
                wrapper.navigator.show(view)
                #expect(wrapper.navigator.waiting != nil, "\(view) without a door")
                wrapper.navigator.giveUp()
            }
        }
    }

    // MARK: - Der Vorhang beim Start

    @Test("Without a start choice the start asks “Who is watching?” — unless the lock applies")
    func launchGate() {
        ProfilePointer.als(nil) {
            let household = Household()
            defer { household.cleanUp() }
            let wrapper = household.wrapper()
            #expect(household.administration.launchGate == .whoIsWatching, "two profiles, no start choice")
            wrapper.showLaunchCurtain()
            #expect(wrapper.sheetState.pending == .accountSwitch)

            let locked = Household().wrapper(devicePin: true, locked: true)
            locked.showLaunchCurtain()
            #expect(locked.sheetState.pending == nil)
        }
    }

    // MARK: - Die Verdrahtung

    private static func code(_ name: String) throws -> String {
        try SourceText.read(name, in: .featuresPhone)
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    @Test("The person sheet shows profiles and the shared actions, no child mode")
    func sheet() throws {
        let sheet = try Self.code("AccountSwitchSheet.swift")
        #expect(sheet.contains("let profile: [Profile]"))
        #expect(sheet.contains("ProfilePicker.actions(switchOnly: !isManageable)"))
        #expect(
            !sheet.contains("[Account]") && !sheet.contains("AccountRow"), "no accounts in the sheet anymore")
        #expect(!sheet.contains("SwitchRow"), "the child mode switch is gone (C10)")
        let placeholder = try Self.code("TabPlaceholder.swift")
        #expect(placeholder.contains("select: { profile in model.switchProfile(profile) }"))
        #expect(placeholder.contains("view == .profile"))
        #expect(placeholder.contains("view == .profileChanged"))
        let model = try Self.code("ShellModel.swift")
        #expect(!model.contains("schalteKindermodus"))
        let switchObserver = ChildProfilePhoneTests.bodyContent("public func switchProfile(", in: model)
        #expect(switchObserver.contains("parentalControls.job(forItem: \"kontowechsel\")"))
    }

    @Test("The child interface hangs on one place and affects tiles and header image")
    func childInterface() throws {
        #expect(try Self.code("ShellView.swift").contains(".environment(\\.surface, model.surface)"))
        #expect(
            try Self.code("ShellView.swift").contains("if model.tabs.isEmpty, !model.isManageable {"),
            "a child without sources does not end up in the setup")
        #expect(try Self.code("StartView.swift").contains("surface.enlarged("))
        #expect(try Self.code("HeaderImage.swift").contains("surface.showsExtras"))
    }
}
