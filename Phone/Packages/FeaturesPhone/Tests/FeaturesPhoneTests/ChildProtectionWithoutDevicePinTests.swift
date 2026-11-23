import Core
import Downloads
import Foundation
import NetworkStatus
import ParentalControls
import PlaylistKit
import ProfileKit
import SourceProbe
import Testing

@testable import FeaturesPhone

/// **A child profile without a device PIN** — the finding from the check evening of 2026-09-25.
///
/// Until then every scope on the phone hung on ``ParentalControls/ProtectionRule/applies``,
/// and that requires a device PIN to be set. A child profile without an allow list and without
/// a device PIN therefore got the whole channel catalog, the portals and the provider catalog.
/// On the TV, `Surface.isInChildMode = accountKind == .kind || applies` applied; the phone
/// now follows it via ``ParentalControls/ProtectionRule/isInChildMode``.
///
/// **The age limit stays tied to the device PIN**, as on the TV: It is a limit
/// for content and not a selection. Only what arrives without approvals is therefore tested.
@MainActor
@Suite("Child protection without a device PIN")
struct ChildProtectionWithoutDevicePinTests {

    let childProfile: Profile = {
        var person = Profile(name: "Child")
        person.kind = .kind
        return person
    }()

    let adult = Profile(name: "Adult")

    private func controls(
        _ person: Profile, pin: Bool = false, groups: Set<ChannelApproval.Group> = []
    ) -> ParentalControlsState {
        let keychainStore = InMemoryStore()
        if pin { _ = Pin(store: keychainStore).set("1234") }
        let ledger = InMemoryStore()
        var profileLedger = ProfileBook()
        profileLedger.create(person)
        profileLedger.write(in: ledger)
        let controls = ParentalControlsState(
            store: UserDefaults(suiteName: UUID().uuidString)!, keychain: keychainStore,
            ledgerStore: ledger)
        if !groups.isEmpty {
            controls.set(
                channelApproval: ChannelApproval(groups: groups), forItem: person.identifier.rawValue)
        }
        return controls
    }

    let state = CatalogState.fromAccesses(jellyfin: true, channelList: true, portals: true)

    private func visibleChannels(_ rule: ProtectionRule) async -> [String]? {
        let source = SourceAssembly.filtered(
            LiveForChildrenPhoneTests.ProbeSource(channels: LiveForChildrenPhoneTests.catalog),
            rule: rule)
        return await source?.channels().channels.map(\.id)
    }

    // MARK: - Channels

    @Test("Child profile without a list and without a device PIN: no channels — as on the TV")
    func withoutListNoChannels() async {
        await ProfilePointer.als(childProfile.identifier.rawValue) {
            let rule = controls(childProfile).rule
            #expect(rule.accountKind == .kind)
            #expect(!rule.applies, "without a device PIN the lock does not apply")
            #expect(rule.scope.isInChildMode, "child mode applies regardless")
            #expect(rule.channelApproval.isEmpty)
            #expect(await visibleChannels(rule) == nil)
        }
    }

    @Test("Child profile with a list, without a device PIN: only the allowed channels")
    func withListOnlyAllowed() async {
        await ProfilePointer.als(childProfile.identifier.rawValue) {
            let rule = controls(childProfile, groups: [LiveForChildrenPhoneTests.children]).rule
            #expect(!rule.applies)
            #expect(await visibleChannels(rule) == ["kimo", "kreisel"])
        }
    }

    @Test("With a device PIN the same situation blocks Live entirely")
    func lockedWithDevicePin() async {
        await ProfilePointer.als(childProfile.identifier.rawValue) {
            let rule = controls(childProfile, pin: true).rule
            #expect(rule.applies)
            #expect(await visibleChannels(rule) == nil)
        }
    }

    // MARK: - Bar, player, downloads

    @Test("Child profile without a device PIN: no Live tab and no portals tab")
    func barWithoutPin() {
        ProfilePointer.als(childProfile.identifier.rawValue) {
            let tabs = ShellModel(catalogs: state, parentalControls: controls(childProfile)).tabs
            #expect(!tabs.contains(.live))
            #expect(!tabs.contains(.portals))
            #expect(tabs.contains(.library))

            let withList = ShellModel(
                catalogs: state,
                parentalControls: controls(childProfile, groups: [LiveForChildrenPhoneTests.children])
            ).tabs
            #expect(withList.contains(.live))
            #expect(!withList.contains(.portals))
        }
    }

    @Test("Child profile without a device PIN: the player plays neither channels nor portals nor providers")
    func playerWithoutPin() {
        ProfilePointer.als(childProfile.identifier.rawValue) {
            let locked = SourceAssembly.blockedOrigins(controls(childProfile).rule)
            #expect(locked == [.channelList, .portals, .provider])
        }
    }

    @Test("Child profile without a device PIN: downloads show no portal titles")
    func downloadsWithoutPin() {
        ProfilePointer.als(childProfile.identifier.rawValue) {
            let portal = DownloadJob(
                id: .init("serieshub|morrowfeld-1-1|https://serieshub.example/redirect/1"), title: "Portal",
                beside: nil, source: .portal, extent: .film, tier: .low,
                estimatedSize: 1_000)
            let own = DownloadJob(
                id: .init("8dec87ad"), title: "Own", beside: nil, source: .jellyfin,
                extent: .film, tier: .low, estimatedSize: 1_000)
            let model = DownloadsModel(networkMonitor: NetworkWatch(), rule: controls(childProfile).rule)
            model.set(
                downloads: Downloads(items: [portal, own], isRunning: []),
                household: StorageBudget(items: [], unrestricted: 1_000_000), durations: [:],
                seen: [])
            #expect(model.rows(forItem: .everything).map(\.title) == ["Own"])
        }
    }

    // MARK: - Adults

    @Test("An adult without a device PIN keeps everything")
    func adultOpen() async {
        await ProfilePointer.als(adult.identifier.rawValue) {
            let rule = controls(adult).rule
            #expect(!rule.scope.isInChildMode)
            #expect(await visibleChannels(rule)?.count == LiveForChildrenPhoneTests.catalog.count)
            #expect(SourceAssembly.blockedOrigins(rule).isEmpty)
            let tabs = ShellModel(catalogs: state, parentalControls: controls(adult)).tabs
            #expect(tabs.contains(.live))
            #expect(tabs.contains(.portals))
        }
    }

    // MARK: - No place asks the lock alone any more

    /// **The scope has exactly one entry point** — ``ParentalControls/ChildScope``,
    /// in the shared package since AP58 R1. Anyone who rebuilds the old questions `delivers` or `zeigtReiter`
    /// or asks only ``ParentalControls/ProtectionRule/applies`` asks only the
    /// lock and leaves a child profile without a device PIN open.
    @Test("No place on the phone filters by applies alone")
    func noPlaceOnlyTakesEffect() throws {
        let forbidden = [
            "rule.delivers(", ".showsTab(", "isInChildMode: rule.applies",
            "withSport: !model.parentalControls.rule.applies", "guard rule.applies else { return source }",
        ]
        var discoveries: [String] = []
        for file in try SourceText.files(in: .featuresPhone) {
            let rows = file.content
                .split(separator: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            for row in rows {
                for patterns in forbidden where row.contains(patterns) {
                    discoveries.append("\(file.name): \(row.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        #expect(discoveries.isEmpty, "\(discoveries.joined(separator: "\n"))")
    }
}
