import CloudSync
import Core
import Flows
import Foundation
import ParentalControls
import PlaylistKit
import ProfileKit
import SwiftUI

/// The profiles of this TV, for the settings — **create, change, switch,
/// remove.**
///
/// **The successor of ``AccountsModel``** (AP41, row 5). The product decision
/// of 2026-09-21: only profiles remain; accounts with their progress and
/// accesses live entirely inside the profiles themselves and are then stored in
/// CloudKit. With that the account list is no longer a list of Jellyfin users but
/// a list of **people**; an access is something one of them has.
///
/// **The management itself has been shared since AP58 R7** (``Flows/ProfileManagement``,
/// finding P6). This type remains as a wrapper for the TV's views that hold it as an
/// `ObservableObject` (`@ObservedObject`, and ``HomeShelf`` listens to
/// `objectWillChange`); it announces every action beforehand and passes it through.
///
/// **A holder above the book and no second store.** The ``ProfileKit/ProfileBook`` lives
/// as a file; this type reads it, hands it to the view and writes it back. What it does
/// **not** do is hold it between two redraws and take it for true —
/// the same intermediate copy that AP41 has just abolished.
final class ProfileModel: ObservableObject {

    /// The shared management — rule and store live there.
    let administration: ProfileManagement

    typealias SessionSequence = ProfileManagement.SessionSequence
    typealias RemovalOutcome = ProfileManagement.RemovalOutcome

    init(
        keychain: SecureStore = SecureStore(),
        store: any KeyValueStore = FileStore(),
        listen: PlaylistStore? = nil,
        cloud: @escaping @MainActor () -> ProfileCloud? = { ProfileCloud.attached },
        startStore: UserDefaults = .standard,
        deviceLists: @escaping @MainActor () -> PlaylistStore? = { nil }
    ) {
        administration = ProfileManagement(
            keychain: keychain, store: store, listen: listen, cloud: cloud,
            startStore: startStore, deviceLists: deviceLists)
    }

    /// The profiles, in the order of the book.
    var profile: [Profile] { administration.profile }
    /// Wer gerade davorsitzt.
    var active: Profile.Identifier? { administration.active }
    var activeProfile: Profile? { administration.activeProfile }
    var canSwitch: Bool { administration.canSwitch }
    var launchGate: StartCurtain { administration.launchGate }
    var nextColor: Profile.ColorTag { administration.nextColor }
    var openQuestions: [ProfileSync.Pair] { administration.openQuestions }

    /// The channel lists — only to notify them after a switch.
    var listen: PlaylistStore? {
        get { administration.listen }
        set { administration.listen = newValue }
    }

    /// Announces the change **before** the action — as `@Published` did.
    private func notify<T>(_ action: () -> T) -> T {
        objectWillChange.send()
        return action()
    }

    func load() { notify { administration.load() } }

    func loadAfterArrival() -> SessionSequence { notify { administration.loadAfterArrival() } }

    @discardableResult
    func create(
        name: String, color: Profile.ColorTag, kind: Profile.Kind, avatar: String?
    ) -> Profile.Identifier? {
        notify { administration.create(name: name, color: color, kind: kind, avatar: avatar) }
    }

    func update(
        _ identifier: Profile.Identifier, name: String, color: Profile.ColorTag, avatar: String?
    ) {
        notify { administration.update(identifier, name: name, color: color, avatar: avatar) }
    }

    @discardableResult
    func save(_ draft: ProfileDraft, existing: Profile?) -> Profile.Identifier? {
        notify { administration.save(draft, existing: existing) }
    }

    func mayRemove(_ identifier: Profile.Identifier) -> Bool { administration.mayRemove(identifier) }

    @discardableResult
    func remove(
        _ identifier: Profile.Identifier, pin: String? = nil,
        mode: ProfileManagement.RemovalMode = .everywhere
    ) -> RemovalOutcome {
        notify { administration.remove(identifier, pin: pin, mode: mode) }
    }

    func isBorrowed(_ identifier: Profile.Identifier) -> Bool { administration.isBorrowed(identifier) }

    /// The profiles from iCloud hidden here — for "Add existing profile".
    func hiddenProfiles() async -> [Profile] { await administration.hiddenProfiles() }

    func restore(_ profile: [Profile]) { notify { administration.restore(profile) } }

    func leave(_ identifier: Profile.Identifier) async throws(CloudError) {
        objectWillChange.send()
        try await administration.leave(identifier)
        objectWillChange.send()
    }

    func isPinSet(_ identifier: Profile.Identifier) -> Bool { administration.isPinSet(identifier) }

    func matchesPin(_ digits: String, forItem identifier: Profile.Identifier) -> Bool {
        administration.matchesPin(digits, forItem: identifier)
    }

    func pinFlow(
        forItem profile: Profile, state: ProfilePinFlow.Situation, cloud: ProfileCloud?
    ) -> ProfilePinFlow {
        administration.pinFlow(forItem: profile, state: state, cloud: cloud)
    }

    func keepBoth(_ pair: ProfileSync.Pair) { notify { administration.keepBoth(pair) } }

    @discardableResult
    func merge(
        _ leaving: Profile.Identifier, in remains: Profile.Identifier,
        pins: [Profile.Identifier: String] = [:]
    ) -> ProfileMerge.SwitchOutcome {
        notify { administration.merge(leaving, in: remains, pins: pins) }
    }

    @discardableResult
    func switchTo(zu identifier: Profile.Identifier, pin: String? = nil) -> ProfileSwitch.SwitchOutcome {
        notify { administration.switchTo(zu: identifier, pin: pin) }
    }
}
