import Core
import Diagnose
import Foundation
import ProfileKit

extension Notification.Name {

    /// **A "forgot PIN" request has changed** — the silent push to the household zone arrived
    /// (``ProfileKit/ProfileCloud/pinEscape``, populated in the `CloudStartup`). Every place that
    /// shows requests then reloads.
    public static let pinEscape = Notification.Name("cinelounge-pinausweg")
}

/// The open "forgot PIN" requests — **parental controls and every profile.**
///
/// **Until 2026-09-25 the phone knew only one** (``ProfileKit/PINFallback/Lock/parentalControls``,
/// the `current` record). Since AP44, however, a **profile** can also carry its own PIN, and
/// its request is called `profile-<Identifier>` (second review, strand C, finding 6). The phone
/// is the fast way — whoever has unlocked it is signed in to the Apple ID — and it did not
/// see exactly these requests.
struct PinFallbacks: Equatable {

    struct ContentEntryRecord: Equatable, Identifiable {
        let lock: PINFallback.Lock
        /// The name of the profile — `nil` for parental controls.
        let name: String?
        let state: PINFallback.State

        var id: String { PINFallback.name(forItem: lock) }
    }

    let entries: [ContentEntryRecord]

    static let none = PinFallbacks(entries: [])

    var isEmpty: Bool { entries.isEmpty }

    /// Assembles the list from what the household zone says.
    ///
    /// **Parental controls first**, then the profiles in the order of the book. A request for a
    /// profile this phone does not know appears with its identifier —
    /// omitting it would mean concealing a running request.
    init(
        parentalControls: PINFallback.State, profile pending: [Profile.Identifier: PINFallback.State],
        ledger: [Profile]
    ) {
        var list: [ContentEntryRecord] = []
        if parentalControls.pending {
            list.append(ContentEntryRecord(lock: .parentalControls, name: nil, state: parentalControls))
        }
        for profile in ledger {
            guard let state = pending[profile.identifier], state.pending else { continue }
            list.append(
                ContentEntryRecord(lock: .profile(profile.identifier), name: profile.name, state: state))
        }
        let known = Set(ledger.map(\.identifier))
        for (identifier, state) in pending.sorted(by: { $0.key.rawValue < $1.key.rawValue })
        where !known.contains(identifier) && state.pending {
            list.append(
                ContentEntryRecord(lock: .profile(identifier), name: identifier.rawValue, state: state))
        }
        entries = list
    }

    init(entries: [ContentEntryRecord]) { self.entries = entries }

    /// The state of one profile — for the badge in the account list.
    func state(forItem identifier: Profile.Identifier) -> PINFallback.State? {
        entries.first { $0.lock == .profile(identifier) }?.state
    }

    /// Reads the requests — **after a round trip to the server**, so that the display does not
    /// show yesterday's state.
    @MainActor
    static func read(cloud: ProfileCloud?, ledgerStore: any KeyValueStore) async -> PinFallbacks {
        guard let cloud else { return .none }
        _ = await cloud.household()?.reconcile()
        return PinFallbacks(
            parentalControls: cloud.pinState(forItem: .parentalControls),
            profile: cloud.openProfileRecoveries(),
            ledger: ProfileBook.read(from: ledgerStore).profile)
    }

    /// Confirms a request — **reconcile first, then write**: a request that another device has
    /// just cancelled must not come back to life.
    @MainActor
    static func confirm(_ lock: PINFallback.Lock, cloud: ProfileCloud, device: String) async -> Bool {
        _ = await cloud.household()?.reconcile()
        let done = cloud.confirmPinRecovery(forItem: lock, device: device)
        Diagnose.step(
            .parentalControls,
            done ? "PIN recovery confirmed" : "PIN recovery: nothing to confirm")
        return done
    }

    /// Cancels a request — likewise after the reconciliation.
    @MainActor
    static func cancel(_ lock: PINFallback.Lock, cloud: ProfileCloud) async {
        _ = await cloud.household()?.reconcile()
        cloud.cancelPinRecovery(forItem: lock)
        Diagnose.step(.parentalControls, "PIN recovery canceled")
    }
}
