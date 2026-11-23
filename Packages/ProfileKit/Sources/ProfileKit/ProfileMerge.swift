import Core
import Foundation
import ParentalControls

/// Two profiles into one — **by hand, from "Manage profiles"** (AP45, 2026-09-25).
///
/// **Irreversible, and therefore with the same guards as a switch.** Whoever
/// merges afterwards sees the history of both and, if they were just in the
/// disappearing profile, sits in the remaining one. If one of the two carries a PIN, it must be
/// entered — otherwise merging would be the way into a protected profile that the
/// keypad in the switcher just closes off.
///
/// **The label of the one that stays, the access of both** — see
/// ``merge(_:in:)``. What is attached to the ID is moved by ``ProfileMove``.
@MainActor
public enum ProfileMerge {

    public enum SwitchOutcome: Equatable, Sendable {
        /// Merged. `wasActive` says whether the viewer was in the disappeared profile —
        /// then the caller must switch the session.
        case merged(Profile, wasActive: Bool)
        /// This profile carries a PIN, and it is missing or wrong.
        case pinRequired(Profile)
        /// One of the two does not exist, it is the same one, or the book could not be
        /// written. **Then nothing is changed.**
        case impossible
    }

    /// Puts `leaving` into `remains`.
    ///
    /// **First the note, then the book, then the move** (cross-check strand C, R4). The
    /// note (``ProfileTombstone``) is the lasting order "`leaving` is now called
    /// `remains`": If the app crashes between book and move, the next startup
    /// catches up (``ProfileMove/episode(_:ledgerStore:keychain:startStore:)``), and a
    /// second call here completes instead of reporting "impossible". Until C2 the note came
    /// last — and after a crash state and PIN lay under an ID that no
    /// book knew anymore.
    ///
    /// **The book is read back.** If writing fails, the note is taken back again
    /// and nothing is changed — the same rule as in
    /// ``ProfileBook/adopt(jellyfin:children:channelLists:wantsPortals:portalPerson:signedIn:fallbackName:version:in:)``.
    ///
    /// - Parameters:
    ///   - pins: the entered PINs per profile.
    ///   - wolke: `nil` without an Apple account — then the note stays on the device and goes up at the
    ///     first ``ProfileCloud/find()``.
    @discardableResult
    public static func perform(
        _ leaving: Profile.Identifier, in remains: Profile.Identifier,
        pins: [Profile.Identifier: String] = [:],
        ledgerStore: any KeyValueStore, keychain: any KeyValueStore,
        startStore: UserDefaults?, cloud: ProfileCloud?
    ) -> SwitchOutcome {
        let ledger = ProfileBook.read(from: ledgerStore)
        guard leaving != remains, let target = ledger.profile.first(where: { $0.identifier == remains })
        else { return .impossible }

        guard let old = ledger.profile.first(where: { $0.identifier == leaving }) else {
            // **Already carried out in the book, the move is missing** — a crash after the book. The
            // note proves that the PINs were right back then; without it `leaving` is unknown.
            let noted = ProfileTombstone.all(from: ledgerStore).contains {
                $0.identifier == leaving && $0.target == remains && !$0.lifted
            }
            guard noted else { return .impossible }
            complete(
                leaving, in: remains, profile: target, ledgerStore: ledgerStore,
                keychain: keychain, startStore: startStore, cloud: cloud)
            return .merged(target, wasActive: false)
        }

        for profile in [target, old] {
            let lock = ProfilePIN(store: keychain, forItem: profile.identifier)
            guard lock.isSet else { continue }
            guard let pin = pins[profile.identifier], lock.matches(pin) else {
                return .pinRequired(profile)
            }
        }

        let combined = merge(old, in: target)
        let wasActive = ledger.active == leaving

        ProfileTombstone.create(leaving, target: remains, in: ledgerStore)

        var fresh = ledger
        fresh.update(remains) { $0 = combined }
        fresh.remove(leaving)
        if wasActive { fresh.switchTo(zu: remains) }
        fresh.write(in: ledgerStore)

        let read = ProfileBook.read(from: ledgerStore)
        guard read.profile.contains(combined),
            !read.profile.contains(where: { $0.identifier == leaving })
        else {
            ProfileTombstone.lift(leaving, in: ledgerStore)
            return .impossible
        }

        complete(
            leaving, in: remains, profile: combined, ledgerStore: ledgerStore,
            keychain: keychain, startStore: startStore, cloud: cloud)
        return .merged(combined, wasActive: wasActive)
    }

    /// Move and cloud — **the part that can be repeated.**
    private static func complete(
        _ leaving: Profile.Identifier, in remains: Profile.Identifier, profile: Profile,
        ledgerStore: any KeyValueStore, keychain: any KeyValueStore,
        startStore: UserDefaults?, cloud: ProfileCloud?
    ) {
        ProfileMove.migrate(
            from: leaving, after: remains, ledgerStore: ledgerStore, keychain: keychain,
            startStore: startStore)

        guard let cloud else { return }
        cloud.bury(leaving, target: remains)
        cloud.cancelPinRecovery(forItem: .profile(leaving))
        // **The migrated PIN straight into the mirror** (AP52) — even before first contact:
        // It carries its own time, and the zone merges by it.
        cloud.passOnPin(remains, from: keychain)
        // **Straight up if the zone was already up** — the same rule as when
        // changing (``ProfileCloud/upload(_:now:onlyNew:)``): Otherwise the next
        // silent push would fetch the zone's old state over the one just merged.
        if let zone = cloud.zone(forItem: remains), zone.recent != nil {
            cloud.upload(profile)
        }
    }

    /// One profile from two: **ID, name, color and picture of the one that stays; the type
    /// is the stricter one; the access of both.**
    ///
    /// **The access is computed by ``ProfileSync/fuse(device:cloud:)``**, with the
    /// one with priority in the role of the device: its access wins, the other's is
    /// added as far as it does not collide. Only one-time items can collide — two
    /// different media-server users or two server persons; a person has
    /// one of each. Channel lists never collide, they all come along.
    ///
    /// **Who has priority:** With the same type, the one that stays — whoever
    /// chooses "merge into X" means X with everything X has. **With different types the child**
    /// (owner's decision on finding 4 of the cross-check strand C): The result is a child profile,
    /// and with the adult's media-server account it would see their whole library — the
    /// type would say "child", and the barrier attached to the server would be open. The child's
    /// account is the stricter, and it stays. **If the child has none, it gets
    /// none** (final review 2026-09-25, N-2) — the rule is at
    /// ``ProfileSync/fuse(device:cloud:)``.
    ///
    /// The picture falls back to the other's if the remaining one never chose one
    /// (`nil`); "No picture" (`""`) is a choice and stays.
    public static func merge(_ leaving: Profile, in remains: Profile) -> Profile {
        let childLeaves = leaving.kind == .kind && remains.kind != .kind
        let credentials =
            childLeaves
            ? ProfileSync.fuse(device: leaving, cloud: remains)
            : ProfileSync.fuse(device: remains, cloud: leaving)
        return Profile(
            identifier: remains.identifier, name: remains.name, color: remains.color,
            kind: credentials.kind, credentials: credentials.credentials,
            avatar: remains.avatar ?? leaving.avatar)
    }
}
