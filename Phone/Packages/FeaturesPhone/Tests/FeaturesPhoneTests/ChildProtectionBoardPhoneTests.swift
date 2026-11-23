import Core
import Downloads
import Foundation
import ParentalControls
import ProfileKit
import Testing

@testable import FeaturesPhone

/// **The phone against the package's truth board** (AP58 R1).
///
/// Each situation is stored the way the phone finds it — profile ledger, Keychain,
/// device lock, profile pointer —, and the ``ParentalControlsState`` reads the rule from it.
/// The questions go through the phone's paths: the origin filter of the source setup, the
/// filtered source, the channel filter, the downloads and the history.
@MainActor
@Suite("Child protection on the phone: the truth table")
struct ChildProtectionBoardPhoneTests {

    /// The rule for this situation — through the same stores as in operation.
    static func rule(_ state: ChildProtectionBoard.Situation) -> ProtectionRule {
        let sharedStore = InMemoryStore()
        let ledger = InMemoryStore()
        var person = Profile(name: state.kind ? "Selin" : "Max")
        person.kind = state.kind ? .kind : .adult
        var profileLedger = ProfileBook()
        profileLedger.create(person)
        profileLedger.write(in: ledger)
        state.create(in: sharedStore, profile: person.identifier.rawValue)
        let controls = ParentalControlsState(
            store: UserDefaults(suiteName: UUID().uuidString)!, keychain: sharedStore,
            ledgerStore: ledger)
        controls.mode.set(state.deviceLocked)
        return ProfilePointer.als(person.identifier.rawValue) { controls.rule }
    }

    static func origin(_ scenario: ChildProtectionBoard.Scenario) -> Catalog.Origin {
        Catalog.Origin(rawValue: scenario.origin) ?? .jellyfin
    }

    /// The phone's answer — `nil` where it has no such path.
    static func reply(
        _ rule: ProtectionRule, _ scenario: ChildProtectionBoard.Scenario,
        _ target: ChildProtectionBoard.Target
    ) async -> Bool? {
        let origin = origin(scenario)
        switch target {
        case .list:
            if origin == .channelList {
                let source = SourceAssembly.filtered(
                    LiveForChildrenPhoneTests.ProbeSource(channels: [ChildProtectionBoard.channels]),
                    rule: rule)
                return !((await source?.channels().channels) ?? []).isEmpty
            }
            guard !SourceAssembly.blockedOrigins(rule).contains(origin) else { return false }
            let source = rule.about(ChildProtectionBoard.Source(scenario.title))
            return !((try? await source.items(in: "tafel", filter: .default)) ?? []).isEmpty
        case .singleTitle:
            guard origin == .jellyfin else { return nil }
            return
                (try? await rule.about(ChildProtectionBoard.Source(scenario.title)).item(
                    id: scenario.title.id))
                != nil
        case .store:
            guard origin != .channelList else { return nil }
            var description = DownloadDescription(
                id: scenario.title.id, title: scenario.title.title, series: scenario.title.seriesID,
                ageRating: scenario.title.ageRating)
            description.seriesClearance = scenario.title.seriesClearance
            description.seriesClearanceChecked = scenario.title.seriesClearanceChecked
            let downloads =
                rule.scope.delivers(PlaybackJob.origin(zu: scenario.title.id).rawValue)
                && rule.shows(downloads: description)
            guard origin == .jellyfin else { return downloads }
            let history = rule.shows(
                history: HistoryEntry(
                    identifier: scenario.title.id, origin: .jellyfin, title: scenario.title.title,
                    approval: HistoryClearance(scenario.title)))
            #expect(downloads == history, "Downloads and history answer differently: \(scenario)")
            return downloads
        }
    }

    @Test("Every title in every situation as in the board — source assembly, filter, downloads, history")
    func title() async {
        var rules: [ChildProtectionBoard.Situation: ProtectionRule] = [:]
        for state in ChildProtectionBoard.situations { rules[state] = Self.rule(state) }
        let discoveries = await ChildProtectionBoard.deviations { state, scenario, target in
            await Self.reply(rules[state]!, scenario, target)
        }
        #expect(
            discoveries.isEmpty,
            "\(discoveries.count) Abweichungen:\n\(discoveries.prefix(20).joined(separator: "\n"))")
    }

    /// The view at which the phone shows a neutral destination.
    static func view(_ target: ChildTarget) -> ViewID? {
        switch target {
        case .mediaLibrary: .library
        case .search: .search
        case .favorites: .favorites
        case .live: .live
        case .portals: .portals
        case .downloads: .downloads
        case .player: .player
        case .legalTexts: .privacy
        case .administration: .settings
        case .profileSwitch, .provider, .sport: nil
        }
    }

    @Test("Every target in every situation as in the board — through the route lock")
    func targets() {
        let discoveries = ChildProtectionBoard.deviations { state, target in
            guard let view = Self.view(target) else { return nil }
            return !KidsTargets.locked(view, rule: Self.rule(state))
        }
        #expect(discoveries.isEmpty, "\(discoveries.joined(separator: "\n"))")
    }
}
