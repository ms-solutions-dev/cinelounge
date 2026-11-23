import Core
import Foundation
import ParentalControls
import ProfileKit
import Testing

@testable import Features

/// **The TV against the package's truth table** (AP58 R1).
///
/// Every state is stored the way the TV finds it — profile book, Keychain, device lock —,
/// and the ``ParentalControlsState`` reads the rule from it. Then the questions are asked
/// over the TV's own routes: the grid of a library (``LibraryModel`` behind the shared
/// filter), the funnel of every opened title, the sidebar's guard.
@MainActor
@Suite("Child protection on the TV: the truth table")
struct ChildProtectionBoardTVTests {

    /// The state for this situation — over the same stores as in operation.
    static func state(_ state: ChildProtectionBoard.Situation) -> ParentalControlsState {
        let store = InMemoryStore()
        let profileStore = InMemoryStore()
        var person = Profile(name: state.kind ? "Selin" : "Max")
        person.kind = state.kind ? .kind : .adult
        var ledger = ProfileBook()
        ledger.create(person)
        ledger.write(in: profileStore)
        state.create(in: store, profile: person.identifier.rawValue)
        let mode = ChildMode(store: UserDefaults(suiteName: UUID().uuidString)!)
        mode.set(state.deviceLocked)
        return ParentalControlsState(
            store: store, childAccounts: ChildAccountList(store: InMemoryStore()),
            profileStore: profileStore, childMode: mode)
    }

    /// The TV's answer — `nil` for stores it does not have.
    static func reply(
        _ rule: ProtectionRule, _ scenario: ChildProtectionBoard.Scenario,
        _ target: ChildProtectionBoard.Target
    ) async -> Bool? {
        let scope = rule.scope
        switch target {
        case .store:
            return nil
        case .singleTitle:
            return scope.opens(scenario.title)
        case .list:
            if scenario.origin == "senderliste" {
                return scope.deliversChannels && !scope.channels([ChildProtectionBoard.channels]).isEmpty
            }
            guard scope.delivers(Origin.forItem(identifier: scenario.title.id)) else { return false }
            let model = LibraryModel(
                source: ChildProtectionBoard.Source(scenario.title),
                library: ChildProtectionBoard.Source.library, rule: rule, store: InMemoryStore())
            await model.load()
            guard case .ready(let title) = model.state else { return false }
            return !title.isEmpty
        }
    }

    @Test("Every title in every situation as on the board — grid and funnel")
    func title() async {
        var rules: [ChildProtectionBoard.Situation: ProtectionRule] = [:]
        for state in ChildProtectionBoard.situations { rules[state] = Self.state(state).rule }
        let discoveries = await ChildProtectionBoard.deviations { state, scenario, target in
            await Self.reply(rules[state]!, scenario, target)
        }
        #expect(
            discoveries.isEmpty,
            "\(discoveries.count) deviations:\n\(discoveries.prefix(20).joined(separator: "\n"))")
    }

    /// The sidebar target at which the TV shows a neutral target.
    static func sidebarTarget(_ target: ChildTarget) -> AppSidebar.Destination? {
        switch target {
        case .mediaLibrary: .media
        case .search: .search
        case .favorites: .favorites
        case .profileSwitch: .accounts
        case .live: .liveProvider("tafel")
        case .portals: .portals
        case .provider: .vod
        case .sport: .sport
        case .administration: .settings
        case .downloads, .player, .legalTexts: nil
        }
    }

    @Test("Every target in every situation as on the board — via the wrapper's guard")
    func targets() {
        let discoveries = ChildProtectionBoard.deviations { state, target in
            guard let target = Self.sidebarTarget(target) else { return nil }
            return ChildGuard.target(afterDiscarding: target, rule: Self.state(state).rule) == target
        }
        #expect(discoveries.isEmpty, "\(discoveries.joined(separator: "\n"))")
    }
}
