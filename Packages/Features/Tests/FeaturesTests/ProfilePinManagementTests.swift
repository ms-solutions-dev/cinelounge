import CloudSync
import Core
import Flows
import Foundation
import ParentalControls
import ProfileKit
import SourceProbe
import Testing

@testable import Features

/// **The profile PIN from "Manage profiles"** (AP52, 2026-09-25) — door, flow and model.
@MainActor
@Suite("Managing the profile PIN")
struct ProfilePinManagementTests {

    // MARK: - The door

    /// **A child must not remove their own PIN when parental controls apply.**
    /// It knows the old profile PIN; the door additionally demands the device's.
    @Test("In a child profile the door asks for the device PIN")
    func childNeedsDevicePin() {
        let kind = ProtectionRule(deviceLocked: false, accountKind: .kind, isPinSet: true)
        #expect(kind.requiresPin(forItem: ProfilePinManagement.door))

        let locked = ProtectionRule(deviceLocked: true, accountKind: .adult, isPinSet: true)
        #expect(locked.requiresPin(forItem: ProfilePinManagement.door))

        let pending = ProtectionRule(deviceLocked: false, accountKind: .adult, isPinSet: true)
        #expect(!pending.requiresPin(forItem: ProfilePinManagement.door), "an adult gets through")
    }

    /// **The door stands at the action**, not only on the board: a button without
    /// `lock.isAllowed` would be the shortest way to get rid of a child profile's PIN.
    /// **Since AP59 N4 the button no longer exists** — one PIN for the household.
    @Test("The management no longer offers a profile PIN")
    func buttonBehindTheDoor() throws {
        let content = try SourceText.read("ProfileView.swift", in: .features)
        #expect(content.range(of: #"identifier: "pin""#) == nil, "the profile PIN button is back")
    }

    // MARK: - The sequence

    @Test("Without a PIN straight to setting, with a PIN the choice first")
    func start() {
        #expect(ProfilePinFlow.start(.maintain, isSet: false) == .fresh(old: nil))
        #expect(ProfilePinFlow.start(.maintain, isSet: true) == .choice)
    }

    /// **The way out reads after a reconciliation and releases only freshly checked** (AP58 R2) —
    /// via ``Flows/PinRecoveryFlow`` as on the phone. Until then the TV read the
    /// mirror synchronously and closed the request on the press without a new check.
    @Test("The escape sheets go through the shared flow")
    func wayOutViaExpiry() throws {
        func code(_ name: String) throws -> String {
            try SourceText.read(name, in: .features)
                .split(separator: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
        }
        let recovery = try code("PinEscapeSheet.swift")
        #expect(recovery.contains("await flow.redeem()"))
        #expect(recovery.contains("await flow.read()"))
        for file in ["PinEscapeSheet.swift", "ProfilePinSheet.swift", "PinDoorSheet.swift"] {
            let text = try code(file)
            #expect(!text.contains("cloud.pinState("), "\(file) reads without reconciling")
            #expect(!text.contains("closePinRecovery("), "\(file) resolves around the flow")
        }
        let administration = try code("ProfilePinManagement.swift")
        #expect(administration.contains("flow.acceptOld("))
        #expect(administration.contains("flow.set("))
    }

    // MARK: - The model

    /// Via ``ProfileModel/pinFlow(forItem:state:cloud:)``, as the view calls it — **including the
    /// cloud**: whatever is set here is immediately in the zone's mirror.
    @Test("Setting, changing and removing via the model's flow go into the cloud")
    func modelWithCloud() throws {
        let server = MockCloud()
        let store = InMemoryStore()
        let secureStore = SecureStore(service: "probe.\(UUID().uuidString)")
        let hub = CloudHub(
            service: server.credential("max"), file: nil,
            device: DeviceDescription(identifier: "tv", name: "tv", model: "Test rig"))
        let cloud = ProfileCloud(
            hub: hub, store: store, moveBundle: secureStore, automatic: false)
        let model = ProfileModel(
            keychain: secureStore, store: store, cloud: { cloud },
            startStore: try #require(UserDefaults(suiteName: "probe.\(UUID().uuidString)")))
        let max = try #require(
            model.create(name: "Max", color: .turquoise, kind: .adult, avatar: nil))
        defer { ProfilePIN(store: secureStore, forItem: max).forget() }

        func top() -> ProfilePIN.ContentEntryRecord? {
            ProfilePINMapping.entry(
                from: cloud.zone(forItem: max)?.read(ProfilePINMapping.contentType) ?? [])
        }

        let profile = try #require(model.profile.first { $0.identifier == max })
        func sheet() -> ProfilePinFlow { model.pinFlow(forItem: profile, state: .maintain, cloud: cloud) }

        #expect(!model.isPinSet(max))
        #expect(sheet().set("1234") == .isSet)
        #expect(model.isPinSet(max))
        #expect(top()?.isSet == true)

        let change = sheet()
        #expect(change.set("5678") == .oldWrong, "no setting without the old one")
        change.chooseChange()
        #expect(change.acceptOld("0000") == .wrong)
        #expect(change.acceptOld("1234") == .next)
        #expect(change.set("5678") == .isSet)
        #expect(model.matchesPin("5678", forItem: max))

        let remove = sheet()
        remove.chooseRemoval()
        #expect(remove.acceptOld("1234") == .wrong)
        #expect(remove.acceptOld("5678") == .removed)
        #expect(!model.isPinSet(max))
        #expect(top()?.isSet == false, "the tombstone is in the cloud")
    }
}
