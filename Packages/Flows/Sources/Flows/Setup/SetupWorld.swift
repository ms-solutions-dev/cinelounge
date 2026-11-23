import Core
import Foundation
import ParentalControls
import ProfileKit

/// What the setup reads from this device before it begins — **the Keychain and the list store
/// turned into the values that ``SetupGate`` and ``SetupMachine`` take.**
///
/// The gate and the machine stay pure and never open a store; this is the one place that does,
/// so that TV and phone ask the same question in the same words. The stores are passed in: the
/// app passes `SecureStore()` and the device's list catalog, the checks an `InMemoryStore`.
nonisolated public enum SetupWorld {

    /// What this device can open, read for the profiles of the book.
    ///
    /// - Parameters:
    ///   - accounts: the media-server accounts with a token here (`SecureStore.allAccounts()`).
    ///   - channelLists: the IDs of the channel lists in the list store.
    ///   - keychain: where the CL-Server device trait lies, one compartment per profile
    ///     (``Core/DeviceTrait``).
    public static func usable(
        book: ProfileBook, accounts: [ServerCredentials], channelLists: Set<String>,
        keychain: any KeyValueStore
    ) -> SetupGate.UsableSources {
        let jellyfin = accounts.compactMap {
            Access.jellyfin(server: $0.serverURL, userID: $0.userID, username: $0.username).legacyAccountID
        }
        let clServer = book.profile.filter {
            DeviceTrait.signedIn(in: ProfileStore(keychain, forItem: $0.identifier.rawValue))
        }
        return SetupGate.UsableSources(
            jellyfinAccounts: Set(jellyfin), channelLists: channelLists,
            clServerProfiles: Set(clServer.map(\.identifier)))
    }

    /// A profile plus what only this device knows about it — the person token and the own age
    /// limit, both in the Keychain and never in the book.
    public static func describe(_ profile: Profile, keychain: any KeyValueStore) -> SetupProfile {
        SetupProfile(
            profile,
            hasPersonTag: PortalMarkerSlot(keychain).tag(forItem: profile.identifier) != nil,
            hasOwnLimit: AgeLimit.read(from: keychain, forItem: profile.identifier.rawValue) != nil)
    }

    /// The profile that came over from the phone — **the one new in the book**, otherwise the one
    /// with the name the pairing reported.
    ///
    /// Neither the pairing nor the handoff hands back an identifier: ``ProfileKit/PairingModel``
    /// reports a name, the handoff a count. A profile from iCloud whose name already stands here is
    /// merged by ``ProfileKit/ProfileSync`` and adds nothing, hence the name as the second answer.
    public static func newcomer(
        before: Set<Profile.Identifier>, in book: ProfileBook, named name: String? = nil
    ) -> Profile? {
        if let fresh = book.profile.first(where: { !before.contains($0.identifier) }) { return fresh }
        guard let name, !name.isEmpty else { return nil }
        return book.profile.first { $0.name == name }
    }

    /// What came over from the phone, as the setup goes on with it.
    public enum Arrival: Sendable, Equatable {
        /// One profile — the TV jumps into its A4.
        case one(Profile)
        /// Several — they stand in A2, and someone picks.
        case several([Profile])
        /// Nothing the setup can name — back to A2.
        case none

        /// What the machine is told — `nil` when nothing arrived.
        public func input(describe: (Profile) -> SetupProfile) -> SetupInput? {
            switch self {
            case .one(let profile): .profileFetched(describe(profile))
            case .several(let profiles): .profilesArrived(profiles.map(describe))
            case .none: nil
            }
        }
    }

    /// The profiles that came over from the phone — **the ones the bundle carried, else the new
    /// ones in the book, else the one with the name the pairing reported.**
    ///
    /// The handoff carries the phone's whole book (`SetupBundle.profile`), and
    /// `Takeover` leaves a profile this device already knows as it is. Reading only the new
    /// ones found nothing when the TV knew them from an interrupted setup, and the code on A2
    /// then did nothing although the handoff had worked.
    ///
    /// - Parameter carried: the identifiers of the profiles in the bundle — empty for the
    ///   pairing, which reports a name.
    public static func arrivals(
        before: Set<Profile.Identifier>, in book: ProfileBook, named name: String? = nil,
        carried: [Profile.Identifier] = []
    ) -> Arrival {
        let brought = book.profile.filter { carried.contains($0.identifier) }
        let fresh = book.profile.filter { !before.contains($0.identifier) }
        for candidates in [brought, fresh] where !candidates.isEmpty {
            return candidates.count == 1 ? .one(candidates[0]) : .several(candidates)
        }
        return newcomer(before: before, in: book, named: name).map(Arrival.one) ?? .none
    }

    /// Takes over another profile's IPTV lists — **the one press of A4** for a second profile
    /// (decision of 2026-11-15 on question 4). Jellyfin and the CL-Server stay each profile's
    /// own; only the lists are a household's.
    ///
    /// - Returns: how many lists the target did not have yet.
    @discardableResult
    public static func copyChannelLists(
        from donor: Profile.Identifier, to target: Profile.Identifier, in store: any KeyValueStore
    ) -> Int {
        var book = ProfileBook.read(from: store)
        guard let lists = book.profile.first(where: { $0.identifier == donor })?.channelLists,
            let owned = book.profile.first(where: { $0.identifier == target })?.channelLists
        else { return 0 }
        let missing = lists.filter { !owned.contains($0) }
        guard !missing.isEmpty else { return 0 }
        book.update(target) { profile in
            for access in missing { profile.create(access) }
        }
        book.write(in: store)
        return missing.count
    }

    /// Where the machine begins — ``SetupGate/entry(book:usable:)`` with the profiles described.
    ///
    /// **A resume whose profile is gone from the book starts fresh** — the pointer can outlive
    /// a profile removed on another device, and A4 for nobody would be a dead end.
    public static func start(
        book: ProfileBook, usable: SetupGate.UsableSources, describe: (Profile) -> SetupProfile
    ) -> SetupMachine.Start? {
        switch SetupGate.entry(book: book, usable: usable) {
        case nil:
            return nil
        case .fresh:
            return .fresh(known: book.profile.map(describe))
        case .resume(let identifier):
            guard let profile = book.profile.first(where: { $0.identifier == identifier }) else {
                return .fresh(known: book.profile.map(describe))
            }
            return .resume(describe(profile))
        }
    }
}
