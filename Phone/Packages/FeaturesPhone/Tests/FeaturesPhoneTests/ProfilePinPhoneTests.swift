import CloudSync
import Core
import Flows
import Foundation
import ParentalControls
import ProfileKit
import SourceProbe
import Testing

@testable import FeaturesPhone

/// **The profile PIN on the phone** — tvOS roadmap AP52, product decision 12 of
/// 2026-09-25.
///
/// Checked **through the connection**: set via ``ProfilePinManagement`` (the same one the
/// sheet calls), required via ``ProfileKit/ProfileSwitch/switchProfile(account:ledgerStore:keychain:pinStore:deviceStore:pin:)``
/// (the same switch as on the TV, which the wrapper takes), migrated via a ``CloudSync/MockCloud`` between phone and
/// TV — and the door in front via ``ShellModel/maintainProfilePin(forItem:)``.
@MainActor
@Suite("AP52 · Profile PIN on the phone")
struct ProfilePinPhoneTests {

    let server = MockCloud()
    static let address = URL(string: "https://jellyfin.example")!

    /// **The IDs are UUIDs, and that is no decoration:** The cloud builds a zone only
    /// for an ID that is a UUID (``ProfileKit/ProfileMapping/zone(forItem:owner:)``).
    /// With a name like "k-child" there would be no zone, the PIN would go up nowhere — and the check
    /// of the migration would be red for the wrong reason.
    let childProfile = Profile(
        identifier: .init(rawValue: "5E1A0000-0000-4000-8000-00000000C0DE"), name: "Selin", kind: .kind,
        credentials: [
            .jellyfin(server: address, userID: "u-selin", username: "Selin")
        ])
    let parents = Profile(
        identifier: .init(rawValue: "3A7A0000-0000-4000-8000-00000000BEEF"), name: "Max",
        credentials: [
            .jellyfin(server: address, userID: "u-max", username: "Max")
        ])

    /// The account whose profile the child is.
    let childAccount = Account.Identifier(server: address.absoluteString, user: "u-selin")

    let early = Date(timeIntervalSince1970: 1_000_000)
    let late = Date(timeIntervalSince1970: 2_000_000)

    @MainActor
    final class Device {
        let cloud: ProfileCloud
        let ledger: InMemoryStore
        let keychain: InMemoryStore
        let pins: ProfilePinManagement

        init(cloud: ProfileCloud, ledger: InMemoryStore, keychain: InMemoryStore, pins: ProfilePinManagement)
        {
            self.cloud = cloud
            self.ledger = ledger
            self.keychain = keychain
            self.pins = pins
        }

        /// The media server session — a separate Keychain per device, **only created
        /// when a switch needs it**: Keychain accesses run here on the
        /// main actor, and every check without a switch should not be held up by it.
        lazy var session: SecureStore = {
            let session = SecureStore(service: "probe.\(UUID().uuidString)")
            for user in ["u-selin", "u-max"] {
                try? session.memorize(
                    ServerCredentials(
                        serverURL: ProfilePinPhoneTests.address, userID: user,
                        username: user, accessToken: "token-\(user)"))
            }
            return session
        }()
    }

    /// A device on the same Apple account — **with both profiles in the ledger, the adults active.**
    func device(_ name: String) -> Device {
        let ledger = InMemoryStore()
        let keychain = InMemoryStore()
        let hub = CloudHub(
            service: server.credential("max"), file: nil,
            device: DeviceDescription(identifier: name, name: name, model: "Test rig"))
        let cloud = ProfileCloud(
            hub: hub, store: ledger, moveBundle: keychain, automatic: false)
        cloud.startStore = nil
        var profileLedger = ProfileBook.read(from: ledger)
        profileLedger.create(parents)
        profileLedger.create(childProfile)
        profileLedger.switchTo(zu: parents.identifier)
        profileLedger.write(in: ledger)
        return Device(
            cloud: cloud, ledger: ledger, keychain: keychain,
            pins: ProfilePinManagement(keychain: keychain, cloud: cloud, device: name))
    }

    /// The switch the wrapper takes — **measured by its result**, so that the checks
    /// below stay readable: `true` means switched.
    func switchProfile(_ device: Device, pin: String?) -> ProfileSwitch.SwitchOutcome {
        ProfileSwitch.episode(
            account: childAccount.stored, ledgerStore: device.ledger,
            keychain: device.session, pinStore: device.keychain,
            deviceStore: InMemoryStore(), pin: pin)
    }

    /// The flow the sheet runs (``Flows/ProfilePinFlow``) — **the same as on the
    /// TV**, with this device's Keychain and cloud.
    func flow(
        _ device: Device, _ state: ProfilePinFlow.Situation = .maintain, now: Date
    )
        -> ProfilePinFlow
    {
        let flow = ProfilePinFlow(
            profile: childProfile, state: state, keychain: device.keychain, cloud: device.cloud,
            device: device.pins.device)
        flow.now = { now }
        return flow
    }

    /// Sets the first PIN via the sheet: without a PIN it starts at setting.
    @discardableResult
    func setFirst(_ digits: String, to device: Device, now: Date) -> ProfilePINMaintenance.SwitchOutcome {
        let sheet = flow(device, now: now)
        #expect(sheet.step == .fresh(old: nil))
        return sheet.set(digits)
    }

    /// Changes via the sheet: choice, old PIN, new.
    func update(
        _ old: String, zu fresh: String, to device: Device, now: Date
    )
        -> ProfilePINMaintenance.SwitchOutcome?
    {
        let sheet = flow(device, now: now)
        sheet.chooseChange()
        guard sheet.acceptOld(old) == .next else { return nil }
        return sheet.set(fresh)
    }

    // MARK: - Set, then the switch requires it

    @Test("Set on the phone, the switch requires it — a wrong PIN does not switch")
    func setIsRequired() {
        let phone = device("phone")
        #expect(setFirst("4711", to: phone, now: early) == .isSet)
        #expect(phone.pins.isSet(childProfile.identifier))

        ProfilePointer.als(parents.identifier.rawValue) {
            #expect(
                ProfileSwitch.lock(
                    account: childAccount.stored, ledgerStore: phone.ledger,
                    pinStore: phone.keychain) == childProfile)
            #expect(switchProfile(phone, pin: nil) == .pinRequired)
            #expect(switchProfile(phone, pin: "0000") == .wrongPin)
            #expect(ProfilePointer.active == parents.identifier.rawValue, "a wrong PIN switches nothing")
            #expect(ProfileBook.read(from: phone.ledger).active == parents.identifier)
            #expect(
                (try? phone.session.loadCredentials()) == nil,
                "the session stays where it was, too")

            #expect(switchProfile(phone, pin: "4711").result?.profile == childProfile)
            #expect(ProfilePointer.active == childProfile.identifier.rawValue)
            #expect(ProfileBook.read(from: phone.ledger).active == childProfile.identifier)
            #expect((try? phone.session.loadCredentials())?.userID == "u-selin")
        }
    }

    @Test("Without a PIN on the target profile the way is free")
    func withoutPinFree() {
        let phone = device("phone")
        ProfilePointer.als(parents.identifier.rawValue) {
            #expect(
                ProfileSwitch.lock(
                    account: childAccount.stored, ledgerStore: phone.ledger,
                    pinStore: phone.keychain) == nil)
            #expect(switchProfile(phone, pin: nil).result != nil)
        }
    }

    // MARK: - The PIN travels

    @Test("Set on the phone, the PIN arrives on the TV — and vice versa")
    func migrates() async {
        let phone = device("phone")
        let tv = device("tv")
        await phone.cloud.reconcile(childProfile)
        await tv.cloud.reconcile(childProfile)

        #expect(setFirst("4711", to: phone, now: early) == .isSet)
        await phone.cloud.reconcile(childProfile)
        await tv.cloud.reconcile(childProfile)
        #expect(tv.pins.matches("4711", forItem: childProfile.identifier), "required on the TV")

        // And in the other direction: changed on the TV, required on the phone.
        #expect(update("4711", zu: "2580", to: tv, now: late) == .isSet)
        await tv.cloud.reconcile(childProfile)
        await phone.cloud.reconcile(childProfile)
        ProfilePointer.als(parents.identifier.rawValue) {
            #expect(switchProfile(phone, pin: "4711") == .wrongPin, "the old one no longer applies")
            #expect(switchProfile(phone, pin: "2580").result != nil)
        }
    }

    // MARK: - Changing and removing require the old one

    @Test("Changing requires the old PIN")
    func changeRequiresOld() {
        let phone = device("phone")
        setFirst("4711", to: phone, now: early)
        // With a PIN the sheet starts at the choice; without the old one nobody reaches the new one.
        let sheet = flow(phone, now: late)
        #expect(sheet.step == .choice)
        #expect(sheet.set("1111") == .oldWrong, "without a choice and the old PIN, nothing is set")
        sheet.chooseChange()
        #expect(sheet.acceptOld("0000") == .wrong)
        #expect(sheet.step == .oldPinForChange)
        #expect(phone.pins.matches("4711", forItem: childProfile.identifier))
        #expect(sheet.acceptOld("4711") == .next)
        #expect(sheet.set("1111") == .isSet)
        #expect(phone.pins.matches("1111", forItem: childProfile.identifier))
    }

    @Test("Removing requires the old one — and the removal travels as a tombstone")
    func removalRequiresOld() async {
        let phone = device("phone")
        let tv = device("tv")
        setFirst("4711", to: phone, now: early)
        await phone.cloud.reconcile(childProfile)
        await tv.cloud.reconcile(childProfile)
        #expect(tv.pins.isSet(childProfile.identifier))

        let sheet = flow(phone, now: late)
        sheet.chooseRemoval()
        #expect(sheet.acceptOld("0000") == .wrong)
        #expect(phone.pins.isSet(childProfile.identifier), "with a wrong PIN it stays")
        #expect(sheet.acceptOld("4711") == .removed)
        #expect(!phone.pins.isSet(childProfile.identifier))
        ProfilePointer.als(parents.identifier.rawValue) {
            #expect(switchProfile(phone, pin: nil).result != nil)
        }

        await phone.cloud.reconcile(childProfile)
        await tv.cloud.reconcile(childProfile)
        #expect(!tv.pins.isSet(childProfile.identifier), "gone on the TV too")
    }

    // MARK: - PIN forgotten

    @Test("A running deadline releases nothing, a confirmation on the TV releases on the phone")
    func escapeResolves() async throws {
        let phone = device("phone")
        let tv = device("tv")
        setFirst("4711", to: phone, now: early)
        await phone.cloud.reconcile(childProfile)
        await tv.cloud.reconcile(childProfile)

        let sheet = flow(phone, .lock, now: late)
        #expect(sheet.step == .lock)
        sheet.openRecovery()
        #expect(sheet.step == .recovery)
        let recovery = try #require(sheet.recovery)
        recovery.request()
        #expect(recovery.state.pending)
        #expect(await !sheet.redeemRecovery())
        #expect(phone.pins.isSet(childProfile.identifier), "a running deadline is no proof")

        _ = await phone.cloud.household()?.reconcile()
        _ = await tv.cloud.household()?.reconcile()
        #expect(tv.cloud.confirmPinRecovery(forItem: .profile(childProfile.identifier), device: "tv"))
        _ = await tv.cloud.household()?.reconcile()

        await recovery.read()
        #expect(recovery.state == .confirmed(device: "phone"))
        #expect(await sheet.redeemRecovery())
        #expect(!phone.pins.isSet(childProfile.identifier))
        ProfilePointer.als(parents.identifier.rawValue) {
            #expect(switchProfile(phone, pin: nil).result != nil)
        }

        // Household-wide: The PIN also drops on the TV, and the request is settled.
        await phone.cloud.reconcile(childProfile)
        await tv.cloud.reconcile(childProfile)
        #expect(!tv.pins.isSet(childProfile.identifier))
        await recovery.read()
        #expect(recovery.state == .none)
    }

    // MARK: - The door of the parental controls

    /// A state with a child profile in the ledger and — if required — a device PIN.
    private func state(pin: Bool) -> ParentalControlsState {
        let keychain = InMemoryStore()
        if pin { _ = Pin(store: keychain).set("1234") }
        let ledger = InMemoryStore()
        var profileLedger = ProfileBook()
        profileLedger.create(childProfile)
        profileLedger.write(in: ledger)
        return ParentalControlsState(
            store: UserDefaults(suiteName: UUID().uuidString)!, keychain: keychain,
            ledgerStore: ledger)
    }

    /// **Decision 20 (2026-09-26):** A child does not see the administration even with a device PIN,
    /// as on the TV. Until then there was a door here behind which the sheet opened.
    @Test("For a child with a device PIN there is neither door nor sheet")
    func noDoorForChild() {
        ProfilePointer.als(childProfile.identifier.rawValue) {
            let backup = state(pin: true)
            #expect(backup.rule.applies)
            let wrapper = ShellModel(parentalControls: backup)
            wrapper.profilePins = { device("phone").pins }

            wrapper.maintainProfilePin(forItem: childProfile)
            #expect(wrapper.navigator.waiting == nil)
            #expect(wrapper.profilePinState == nil)
        }
    }

    /// **An adult with a device PIN and device lock keeps the door.**
    @Test("For an adult with a lock the button requires the device PIN")
    func doorForAdult() {
        ProfilePointer.als(parents.identifier.rawValue) {
            let backup = state(pin: true)
            backup.mode.set(true)
            #expect(backup.rule.applies)
            let wrapper = ShellModel(parentalControls: backup)
            wrapper.profilePins = { device("phone").pins }

            wrapper.maintainProfilePin(forItem: parents)
            #expect(
                wrapper.navigator.waiting
                    == .door(
                        identifier: ProfilePinManagement.door,
                        reason: LockedDoors.reason(ProfilePinManagement.door) ?? ""))
            #expect(wrapper.profilePinState == nil, "no sheet opens in front of the door")

            // The right device PIN opens — only then does the sheet come.
            if let job = wrapper.navigator.waiting {
                #expect(backup.verify("1234", forItem: job))
            }
            wrapper.navigator.letPass()
            #expect(wrapper.profilePinState == .maintain(parents))
        }
    }

    /// **Without an active lock the sheet opens for an adult without a device PIN** —
    /// for a child without a device PIN not at all (``KidsTargets``, finding of 2026-09-25): It
    /// could otherwise give itself a profile PIN.
    @Test("Without an effective lock: open for adults, absent for a child")
    func withoutLockOpen() {
        ProfilePointer.als(parents.identifier.rawValue) {
            let backup = state(pin: false)
            #expect(!backup.rule.applies)
            let wrapper = ShellModel(parentalControls: backup)
            wrapper.profilePins = { device("phone").pins }
            wrapper.maintainProfilePin(forItem: parents)
            #expect(wrapper.navigator.waiting == nil)
            #expect(wrapper.profilePinState == .maintain(parents))
        }
        ProfilePointer.als(childProfile.identifier.rawValue) {
            let wrapper = ShellModel(parentalControls: state(pin: false))
            wrapper.profilePins = { device("phone").pins }
            #expect(!wrapper.isManageable)
            wrapper.maintainProfilePin(forItem: childProfile)
            #expect(wrapper.profilePinState == nil)
        }
    }

    // MARK: - The connection in the shell

    @Test("The shell asks the latch before the session and passes the PIN to the profile switch")
    func shellLocks() throws {
        let model = try SourceText.read("ShellModel.swift", in: .featuresPhone)
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        let switchObserver = ChildProfilePhoneTests.bodyContent("public func switchAccount(", in: model)
        #expect(!switchObserver.contains("adoptAccount("), "past the latch")
        #expect(switchObserver.contains("lock(account)"))
        let lock = ChildProfilePhoneTests.bodyContent("private func lock(", in: model)
        #expect(lock.contains("ProfileSwitch.lock("))
        let takeover = ChildProfilePhoneTests.bodyContent("private func adoptAccount(", in: model)
        let beforeSession = takeover.components(separatedBy: "accounts.switchTo(").first ?? ""
        #expect(
            beforeSession.contains("ProfileSwitch.episode("),
            "the switch with the latch comes before the session")
        #expect(beforeSession.contains("case .pinRequired, .wrongPin:\n            return"))
        #expect(takeover.contains("pin: pin)"))
    }
}
