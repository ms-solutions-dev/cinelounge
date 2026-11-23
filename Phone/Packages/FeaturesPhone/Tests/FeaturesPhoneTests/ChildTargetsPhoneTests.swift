import Core
import Foundation
import ParentalControls
import ProfileKit
import SourceProbe
import Testing

@testable import FeaturesPhone

/// **A child without a device PIN does not reach the administration** — finding of 2026-09-25,
/// the yardstick since AP58 R1 is ``ParentalControls/ChildScope/isAllowed(_:)`` for both programs.
@MainActor
@Suite("Child targets on the phone")
struct ChildTargetsPhoneTests {

    let childProfile: Profile = {
        var person = Profile(name: "Sam")
        person.kind = .kind
        return person
    }()

    let adult = Profile(name: "Alex")

    private func state(_ person: Profile, pin: Bool = false) -> ParentalControlsState {
        let secure = InMemoryStore()
        if pin { _ = Pin(store: secure).set("1234") }
        let ledger = InMemoryStore()
        var profileLedger = ProfileBook()
        profileLedger.create(childProfile)
        profileLedger.create(adult)
        profileLedger.write(in: ledger)
        return ParentalControlsState(
            store: UserDefaults(suiteName: UUID().uuidString)!, keychain: secure,
            ledgerStore: ledger)
    }

    /// Everything a household administers — **a child may change none of it.**
    static let administration: [ViewID] = [
        .settings, .accounts, .newAccount, .accountSettings, .migration, .certificates,
        .handoff, .setup, .parentalControls, .approvals, .forgotPin, .pinReset,
        .channelLists, .newChannelList, .editChannelList, .liveSettings, .groups,
        .portalSettings, .cloud, .otherDevices, .storage, .appearance, .arrangeShelves, .playback,
        .ratingsSettings, .diagnose, .log, .report, .profile, .profileChanged,
    ]

    @Test("Every management view is the management target, no other")
    func complete() {
        for view in ViewID.allCases {
            #expect(
                (KidsTargets.target(view) == .administration) == Self.administration.contains(view),
                "\(view)")
        }
    }

    /// **Since R1 as on the TV** (AP58): A child never reaches portals, Live only with
    /// its allow list — also via a jump from outside.
    @Test("A child never reaches portals and reaches Live only with a list")
    func liveAndPortals() {
        let withoutList = ProtectionRule(deviceLocked: false, accountKind: .kind, isPinSet: false)
        let withList = withoutList.using(
            channelApproval: ChannelApproval(groups: [ChildProtectionBoard.group]))
        #expect(KidsTargets.locked(.portals, rule: withList))
        #expect(KidsTargets.locked(.detailPortal, rule: withList))
        #expect(KidsTargets.locked(.live, rule: withoutList))
        #expect(!KidsTargets.locked(.live, rule: withList))
        #expect(!KidsTargets.locked(.portals, rule: .pending))
    }

    @Test("A child without a device PIN reaches no management view")
    func childWithoutPin() {
        ProfilePointer.als(childProfile.identifier.rawValue) {
            let wrapper = ShellModel(parentalControls: state(childProfile))
            #expect(!wrapper.isManageable)
            for view in Self.administration {
                wrapper.navigator.show(view)
                #expect(wrapper.navigator.current != view, "\(view) is reachable")
                #expect(wrapper.navigator.waiting == nil)
            }
            wrapper.navigator.show(.search)
            #expect(wrapper.navigator.current == .search)
        }
    }

    /// **Decision 20 (2026-09-26):** Even with a device PIN a child sees no
    /// administration, as on the TV. Until then a door stood there.
    @Test("A child with a device PIN reaches no management view, not even through a door")
    func childWithPin() {
        ProfilePointer.als(childProfile.identifier.rawValue) {
            let wrapper = ShellModel(parentalControls: state(childProfile, pin: true))
            #expect(!wrapper.isManageable)
            for view in Self.administration {
                wrapper.navigator.show(view)
                #expect(wrapper.navigator.current != view, "\(view) is reachable")
                #expect(wrapper.navigator.waiting == nil, "\(view) has a door instead of none")
            }
        }
    }

    /// **An adult with a device PIN keeps their doors**, even if the device lock
    /// turns on child mode.
    @Test("An adult with a device PIN and device lock stands at the door")
    func adultWithPinAndLock() {
        ProfilePointer.als(adult.identifier.rawValue) {
            let parentalControls = state(adult, pin: true)
            parentalControls.mode.set(true)
            let wrapper = ShellModel(parentalControls: parentalControls)
            #expect(parentalControls.rule.applies)
            #expect(wrapper.isManageable)
            wrapper.navigator.show(.settings)
            #expect(wrapper.navigator.waiting != nil, "the device PIN is required")
        }
    }

    @Test("Without a child everything is open")
    func adultProfileUnaffected() {
        ProfilePointer.als(adult.identifier.rawValue) {
            let wrapper = ShellModel(parentalControls: state(adult))
            #expect(wrapper.isManageable)
            wrapper.navigator.show(.settings)
            #expect(wrapper.navigator.current == .settings)
        }
    }

    /// **Anyone switching from an adult to a child profile does not end up in its Settings.**
    @Test("Switching to a child profile drops the open management view")
    func switchCleansUp() {
        let kind = state(childProfile)
        ProfilePointer.als(adult.identifier.rawValue) {
            let wrapper = ShellModel(parentalControls: kind)
            wrapper.navigator.show(.settings)
            wrapper.navigator.show(.parentalControls)
            #expect(wrapper.navigator.overlay == [.settings, .parentalControls])
            ProfilePointer.als(childProfile.identifier.rawValue) {
                wrapper.cloudArrived()
                #expect(wrapper.navigator.overlay.isEmpty)
            }
        }
    }

    @Test("The person sheet gets management only where it is allowed")
    func sheetWired() throws {
        let placeholder = try SourceText.read("TabPlaceholder.swift", in: .featuresPhone)
        #expect(placeholder.contains("isManageable: model.isManageable"))
        let sheet = try SourceText.read("AccountSwitchSheet.swift", in: .featuresPhone)
        #expect(sheet.contains("if isManageable { administration }"))
        #expect(sheet.contains("change: isManageable ? changeProfilePicture : nil"))
    }
}
