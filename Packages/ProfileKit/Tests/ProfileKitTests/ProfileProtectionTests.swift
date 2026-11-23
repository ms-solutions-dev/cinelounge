import Core
import Foundation
import ParentalControls
import Testing

@testable import ProfileKit

/// **Parental controls hang on the person and no longer on the device** (AP41).
@Suite("The protection per profile")
struct ProfileProtectionTests {

    /// **The bug that existed before.** Limit, lock and mapping board lay under
    /// **one** key per device: Whoever set their own limit changed the child's
    /// limit.
    @Test("Two profiles have two limits")
    func twoLimits() {
        let sharedStore = InMemoryStore()
        let parents = Profile(name: "Eltern")
        let kind = Profile(name: "Kind", kind: .kind)

        AgeLimit.write(.from18, in: sharedStore, forItem: parents.identifier.rawValue)
        AgeLimit.write(.from6, in: sharedStore, forItem: kind.identifier.rawValue)

        #expect(
            ProtectionRule.forItem(parents, deviceLocked: false, keychain: sharedStore).limit
                == .from18)
        #expect(
            ProtectionRule.forItem(kind, deviceLocked: false, keychain: sharedStore).limit
                == .from6)
    }

    @Test("The profile's kind becomes the account kind")
    func kindBecomesAccountKind() {
        let sharedStore = InMemoryStore()
        #expect(
            ProtectionRule.forItem(
                Profile(name: "Kind", kind: .kind), deviceLocked: false, keychain: sharedStore
            ).accountKind == .kind)
        #expect(
            ProtectionRule.forItem(
                Profile(name: "Eltern"), deviceLocked: false, keychain: sharedStore
            ).accountKind == .adult)
    }

    /// **The device baseline remains the named exception** — the TV in the child's room
    /// is locked for everyone, no matter who logs in.
    @Test("Without a profile the device baseline applies alone")
    func withoutProfileDeviceApplies() {
        let sharedStore = InMemoryStore()
        let rule = ProtectionRule.forItem(nil, deviceLocked: true, keychain: sharedStore)
        #expect(rule.deviceLocked)
        #expect(rule.accountKind == .adult)
    }

    // MARK: - The takeover

    /// **It goes to the children and not to everyone.** Giving every profile a limit
    /// would mean pushing one onto an adult that was never meant for them;
    /// giving it to no one would mean leaving a child profile open after the update.
    @Test("The device limit goes to the child profiles")
    func adoptionForChildren() {
        let sharedStore = InMemoryStore()
        AgeLimit.write(.from12, in: sharedStore)
        UnrecognizedLock.write(false, in: sharedStore)
        var ledger = ProfileBook()
        let parents = Profile(name: "Eltern")
        let kind = Profile(name: "Kind", kind: .kind)
        ledger.create(parents)
        ledger.create(kind)

        #expect(ProfileBackup.adopt(ledger, keychain: sharedStore) == 1)

        #expect(AgeLimit.read(from: sharedStore, forItem: kind.identifier.rawValue) == .from12)
        #expect(AgeLimit.read(from: sharedStore, forItem: parents.identifier.rawValue) == nil)
        #expect(UnrecognizedLock.read(from: sharedStore, forItem: kind.identifier.rawValue) == false)
        // **The device baseline stays** — whoever set it meant "this device".
        #expect(AgeLimit.read(from: sharedStore) == .from12)
    }

    /// **A second takeover must not loosen.** Otherwise it would replace a limit set in the meantime
    /// with the device's old one — and nobody would see it.
    @Test("A set limit is not overwritten")
    func neverLoosen() {
        let sharedStore = InMemoryStore()
        AgeLimit.write(.from18, in: sharedStore)
        var ledger = ProfileBook()
        let kind = Profile(name: "Kind", kind: .kind)
        ledger.create(kind)
        AgeLimit.write(.from6, in: sharedStore, forItem: kind.identifier.rawValue)

        #expect(ProfileBackup.adopt(ledger, keychain: sharedStore) == 0)

        #expect(AgeLimit.read(from: sharedStore, forItem: kind.identifier.rawValue) == .from6)
    }

    @Test("Without a device limit nothing happens")
    func withoutDeviceLimit() {
        let sharedStore = InMemoryStore()
        var ledger = ProfileBook()
        ledger.create(Profile(name: "Kind", kind: .kind))

        #expect(ProfileBackup.adopt(ledger, keychain: sharedStore) == 0)
    }

    /// **The mapping board moves along.** Without it the child would stand in front of
    /// thirty missing titles after the update, whose rating is "not classified" — and the
    /// parent would look for the bug in the app.
    @Test("The assignment board moves along")
    func boardMigrates() {
        let sharedStore = InMemoryStore()
        AgeLimit.write(.from12, in: sharedStore)
        UnrecognizedRatings(counted: ["TV-MA": 31], assignments: ["TV-MA": 18])
            .save(to: sharedStore)
        var ledger = ProfileBook()
        let kind = Profile(name: "Kind", kind: .kind)
        ledger.create(kind)

        ProfileBackup.adopt(ledger, keychain: sharedStore)

        let rule = ProtectionRule.forItem(kind, deviceLocked: false, keychain: sharedStore)
        #expect(rule.assignments == ["TV-MA": 18])
    }

    /// **The device baseline and the person stand side by side**, and the stricter one
    /// applies — the same rule as since 2026-09-06, only that "both" now means person and
    /// device instead of account and device.
    @Test("A locked device also locks an adult profile")
    func deviceTightens() {
        let sharedStore = InMemoryStore()
        Pin(store: sharedStore).set("1234")
        let parents = Profile(name: "Eltern")

        #expect(
            ProtectionRule.forItem(parents, deviceLocked: true, keychain: sharedStore).applies)
        #expect(
            ProtectionRule.forItem(parents, deviceLocked: false, keychain: sharedStore).applies
                == false)
    }

    // MARK: - The allow list for channels (AP52)

    private static let children = ChannelApproval.Group(list: "l", name: "DE| Kinder")
    private static let news = ChannelApproval.Group(list: "l", name: "DE| News")

    @Test("One profile's rule carries its allow list, another's does not")
    func ruleCarriesList() {
        let sharedStore = InMemoryStore()
        let kind = Profile(name: "Kind", kind: .kind)
        let parents = Profile(name: "Eltern")
        ChannelApproval(groups: [Self.children]).save(to: sharedStore, forItem: kind.identifier.rawValue)

        #expect(
            ProtectionRule.forItem(kind, deviceLocked: false, keychain: sharedStore)
                .channelApproval.contains(Self.children))
        #expect(
            ProtectionRule.forItem(parents, deviceLocked: false, keychain: sharedStore)
                .channelApproval.isEmpty)
    }

    @MainActor
    @Test("On migration the list moves along — as a whole onto an empty one, otherwise the intersection")
    func moveCarriesList() {
        let sharedStore = InMemoryStore()
        let ledger = InMemoryStore()
        let old = Profile.Identifier.fresh()
        let fresh = Profile.Identifier.fresh()
        ChannelApproval(groups: [Self.children, Self.news]).save(to: sharedStore, forItem: old.rawValue)

        ProfileMove.migrate(
            from: old, after: fresh, ledgerStore: ledger, keychain: sharedStore, startStore: nil)
        #expect(
            ChannelApproval.load(from: sharedStore, forItem: fresh.rawValue).groups == [
                Self.children, Self.news,
            ])
        #expect(ChannelApproval.load(from: sharedStore, forItem: old.rawValue).isEmpty, "the old one is gone")

        // If the remaining one already has one, the stricter applies: the intersection.
        let third = Profile.Identifier.fresh()
        ChannelApproval(groups: [Self.children]).save(to: sharedStore, forItem: third.rawValue)
        ProfileMove.migrate(
            from: fresh, after: third, ledgerStore: ledger, keychain: sharedStore, startStore: nil)
        #expect(ChannelApproval.load(from: sharedStore, forItem: third.rawValue).groups == [Self.children])
    }
}
