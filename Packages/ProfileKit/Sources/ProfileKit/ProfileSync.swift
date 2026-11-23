import Core
import Foundation

/// **What becomes of two profile lists on first contact with iCloud** (AP48, 2026-09-24).
///
/// **The bug this fixes is not a missing feature but a duplicated
/// person.** ``ProfileCloud/adopt(_:)`` compares by **identifier** — and for
/// the same person on two devices that is different: on the TV it is created on the first
/// start from what the device has (``ProfileBook/adopt(jellyfin:…)``), on the iPhone
/// likewise, and both assign a fresh ``ProfileKit/Identifier/fresh()``. If iCloud is then switched
/// on, the switcher shows **two profiles with the same name** — and whoever takes the wrong one finds
/// their state missing.
///
/// **Merging goes by name, because there is nothing better.** Not every profile has a
/// media server account (a device with only a channel list yields one without), an identifier is new per device, and the app does not know a birth date.
/// The name is what a person typed in themselves — and if it is the same on both devices,
/// the assumption "same person" is better than any other.
public enum ProfileSync {

    /// A pair that looks like the same person without proving it.
    ///
    /// **Both stay**, and the switcher asks "merge?". Merging automatically
    /// would mean making two people one because they share a
    /// Jellyfin access — and that happens in a household.
    public struct Pair: Sendable, Equatable, Hashable, Codable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case device = "geraet"
            case cloud = "wolke"
        }

        public let device: Profile.Identifier
        public let cloud: Profile.Identifier

        public init(device: Profile.Identifier, cloud: Profile.Identifier) {
            self.device = device
            self.cloud = cloud
        }
    }

    /// The key under which the open questions lie.
    public static let questionsKey = "profiles.mergeQuestions"

    /// Stores the open pairs — **because otherwise they fall on the floor.**
    ///
    /// **Found on 2026-09-24, in the own build of the same day:** the computation delivers
    /// `toAsk`, and ``ProfileCloud/adopt(_:)`` used **none** of it. The
    /// merge ran correctly, the open question vanished — and AP48's promise
    /// "anything unclear stays two profiles, the switcher shows 'merge?'" was thus only
    /// half kept: two did remain, but nobody could ever learn why.
    ///
    /// **An empty list deletes the entry.** Whoever has answered a question should
    /// not see it again at the next sync; an empty entry would moreover not be distinguishable from
    /// "never asked".
    public static func memorize(_ pairs: [Pair], in store: any KeyValueStore) {
        guard !pairs.isEmpty else {
            try? store.remove(questionsKey)
            return
        }
        guard let raw = try? JSONEncoder().encode(pairs),
            let text = String(data: raw, encoding: .utf8)
        else { return }
        try? store.set(text, for: questionsKey)
    }

    /// The open questions — empty if none are pending.
    public static func openQuestions(from store: any KeyValueStore) -> [Pair] {
        guard let text = try? store.value(for: questionsKey),
            let raw = text.data(using: .utf8),
            let pairs = try? JSONDecoder().decode([Pair].self, from: raw)
        else { return [] }
        return pairs
    }

    /// **The whole process in one place: merge, store, remember questions.**
    ///
    /// **Why not in ``ProfileCloud/adopt(_:)``, where it comes from:** there it hangs on
    /// a holder that needs CloudKit, and so cannot be checked without the cloud.
    /// Exactly that hid a bug on 2026-09-24 — the counter-test stayed **green**
    /// although remembering the open questions had been removed: the checks saw the computation
    /// and the store, but not the connection, and the connection was the finding. As a
    /// computation with a store the whole chain is checkable.
    ///
    /// - Returns: how many changes to the book arose — for the check and for
    ///   the trace, not for operation.
    @discardableResult
    public static func adopt(cloud: [Profile], in store: any KeyValueStore) -> Int {
        guard !cloud.isEmpty else { return 0 }
        let ledger = ProfileBook.read(from: store)
        let result = merge(device: ledger.profile, cloud: cloud)
        guard result.profile != ledger.profile else { return 0 }

        // **The active identifier migrates along.** Without this line it would fall back in
        // ``ProfileBook/init(profile:active:)`` to `profile.first` — and when merging that is a **different
        // person**, not the one currently watching. For the same
        // reason an empty "aktiv" stays empty (``ProfileBook/clearActive()``).
        var fresh = ProfileBook(profile: result.profile, active: result.now(ledger.active))
        if ledger.active == nil { fresh.clearActive() }
        fresh.write(in: store)
        // **The open questions are to be stored and not discarded** (AP45/AP48): what is
        // called the same is merged; what only **looks** the same — the same
        // media server access under different names — stays two profiles and is
        // asked about.
        memorize(result.toAsk, in: store)
        return abs(result.profile.count - ledger.profile.count) + result.moves.count
    }

    /// Whether this profile is part of an open question.
    ///
    /// **Both sides count.** The question is "are these two people or one?", and
    /// it appears on **both** circles: whoever marked only one would leave open which
    /// other one it belongs with — and with three profiles that cannot be guessed.
    public static func isInQuestion(_ identifier: Profile.Identifier, under pairs: [Pair]) -> Bool {
        pairs.contains { $0.device == identifier || $0.cloud == identifier }
    }

    /// Removes an answered pair from the list.
    ///
    /// **Both answers remove it** — "merge" and "keep two". The second is
    /// not a non-answer: whoever gives it has decided, and asking the question again
    /// would be not believing their decision.
    public static func answer(_ pair: Pair, in store: any KeyValueStore) {
        memorize(openQuestions(from: store).filter { $0 != pair }, in: store)
    }

    /// What becomes of the two lists.
    public struct Outcome: Sendable, Equatable {
        /// The profiles that belong in the book.
        public let profile: [Profile]
        /// The pairs about which the switcher has to ask.
        public let toAsk: [Pair]

        /// **Where a device identifier has migrated to** — and without this information the
        /// viewer jumps to a foreign profile on first iCloud contact.
        ///
        /// ``ProfileBook/init(profile:active:)`` checks whether the active identifier still
        /// occurs, and otherwise falls back to `profile.first` — that is right for a
        /// deleted profile and wrong for a **renamed** one: whoever is currently watching
        /// then lands on the first-named person in the book. Exactly that is prevented by
        /// ``ProfileCloud/adopt(_:)`` in its DocC ("not on a different profile in the middle
        /// of a film"), and without this mapping it would have broken precisely there.
        public let migrated: [Profile.Identifier: Profile.Identifier]

        /// **Which cloud identifier is absorbed into a device identifier** — the opposite direction to
        /// ``migrated``, when this device's identifier wins (``wins(_:about:)``).
        ///
        /// Nothing moves locally here, because under the cloud identifier there is nothing on this
        /// device. But it needs a tombstone with a target: otherwise the
        /// next start would find its zone again, and the device it belongs to would never learn
        /// where it should follow.
        public let absorbed: [Profile.Identifier: Profile.Identifier]

        public init(
            profile: [Profile], toAsk: [Pair],
            migrated: [Profile.Identifier: Profile.Identifier] = [:],
            absorbed: [Profile.Identifier: Profile.Identifier] = [:]
        ) {
            self.profile = profile
            self.toAsk = toAsk
            self.migrated = migrated
            self.absorbed = absorbed
        }

        /// Every identifier that disappears, with its target — both directions.
        public var moves: [Profile.Identifier: Profile.Identifier] {
            migrated.merging(absorbed) { first, _ in first }
        }

        /// The identifier that applies now — the same one if nothing migrated.
        public func now(_ identifier: Profile.Identifier?) -> Profile.Identifier? {
            guard let identifier else { return nil }
            return migrated[identifier] ?? identifier
        }
    }

    /// Merges what is the same person.
    ///
    /// **The cloud's identifier applies, the device's accesses stay** — and that is the
    /// only split in which nothing is lost. The identifier has to be the same on all
    /// devices, otherwise the same name means someone else here than there; the
    /// accesses, on the other hand, apply **only here**: this media server is in this house,
    /// this channel list is set up on this TV. Pushing them into the cloud
    /// would mean giving the phone the channels of a TV.
    ///
    /// **Which identifier stays is decided by the identifier itself and not by the side**
    /// (counter-check strand C, R1/R1b): the lexicographically smaller one, see
    /// ``wins(_:about:)``. Until C2 the cloud's always applied — and two devices whose
    /// profiles were both already up there each took the other's: they **swapped** their
    /// identifiers instead of agreeing, and the next start found the abandoned zone
    /// again.
    ///
    /// **When the kinds disagree, the stricter rule wins.** If one side says
    /// "child" and the other "adult", **child** applies. Otherwise the removal of
    /// parental controls would depend on which device synced last — and a
    /// protection that depends on an order is none.
    ///
    /// **Equal identifiers first, then the names** (on-device test 2026-09-28, iPhone with two
    /// profiles of the same name). Until then both ran in one pass in the device's order: if the profile known only
    /// here stood before the one whose identifier is also up there, it grabbed by
    /// name the latter's cloud entry — and wrote a tombstone "the cloud identifier was absorbed into me", although it lived on in the same result. Another device with exactly
    /// this identifier then moved.
    ///
    /// **A second profile with the same name, known only here, is absorbed into the one that
    /// is up there.** Otherwise there would remain two profiles of the same name — and the IPTV list hung on the one
    /// that is not currently watching.
    public static func merge(device: [Profile], cloud: [Profile]) -> Outcome {
        var pending: [Pair] = []
        let top = Set(cloud.map(\.identifier))
        var consumed = Set(device.map(\.identifier)).intersection(top)
        var migrated: [Profile.Identifier: Profile.Identifier] = [:]
        var absorbed: [Profile.Identifier: Profile.Identifier] = [:]
        // Per device identifier, what stands in its place.
        var location: [Profile.Identifier: Profile] = [:]
        var twins: Set<Profile.Identifier> = []

        for own in device {
            guard let equal = cloud.first(where: { $0.identifier == own.identifier }) else { continue }
            location[own.identifier] = fuse(device: own, cloud: equal)
        }

        for own in device where !top.contains(own.identifier) {
            if let sameNamed = cloud.first(where: {
                !consumed.contains($0.identifier) && sameName($0.name, own.name)
            }) {
                consumed.insert(sameNamed.identifier)
                let combined = fuse(device: own, cloud: sameNamed)
                if wins(own.identifier, about: sameNamed.identifier) {
                    absorbed[sameNamed.identifier] = own.identifier
                    location[own.identifier] = combined.withIdentifier(own.identifier)
                } else {
                    migrated[own.identifier] = sameNamed.identifier
                    location[own.identifier] = combined
                }
                continue
            }

            if let twin = device.first(where: {
                top.contains($0.identifier) && sameName($0.name, own.name)
            }), let target = location[twin.identifier] {
                location[twin.identifier] = takeAccesses(from: own, in: target)
                migrated[own.identifier] = target.identifier
                twins.insert(own.identifier)
                continue
            }

            // Different names, but the same media server user: that looks like
            // the same person ("Alex" here, "Sam" there) and can also be a
            // shared access. Both stay, the switcher asks.
            if let account = own.jellyfin,
                let suspect = cloud.first(where: {
                    !consumed.contains($0.identifier) && $0.jellyfin == account
                })
            {
                pending.append(Pair(device: own.identifier, cloud: suspect.identifier))
            }
            location[own.identifier] = own
        }

        var result = device.compactMap { twins.contains($0.identifier) ? nil : location[$0.identifier] }
        // What is in the cloud and corresponds to nothing here is added: a profile
        // that was created on the iPhone and has never seen this TV.
        result += cloud.filter { !consumed.contains($0.identifier) }

        return Outcome(
            profile: result, toAsk: pending, migrated: migrated, absorbed: absorbed)
    }

    /// The accesses of a profile that is absorbed, into the remaining one — **the remaining one's own win**,
    /// a unique one (media server, server person) comes only if there is none there yet.
    /// Label and kind stay, unless the absorbed one is stricter.
    static func takeAccesses(from leaving: Profile, in remains: Profile) -> Profile {
        var combined = remains
        combined.kind = stricter(remains.kind, leaving.kind)
        for credential in leaving.credentials where !combined.credentials.contains(credential) {
            guard
                !credential.onlyOnce || !combined.credentials.contains(where: { $0.kind == credential.kind })
            else { continue }
            guard !(combined.kind == .kind && leaving.kind != .kind && credential.onlyOnce) else { continue }
            combined.create(credential)
        }
        if combined.avatar == nil { combined.avatar = leaving.avatar }
        return combined
    }

    /// Whether, when merging by name, `links` stays and `right` is absorbed into it.
    ///
    /// **The lexicographically smaller identifier wins** (in the spelling of
    /// ``ProfileTombstone/norm(_:)``). That is the robust one of the possible rules, because it
    /// depends **only on the two identifiers**: two devices that see the same pair
    /// make the same choice — regardless of which syncs first, whether one was offline
    /// and which clock is wrong. "The older zone" would sound more natural, but would need
    /// a point in time that CloudKit does not provide for zones; the creation date of a
    /// record is stamped by the writing device, and a device that created offline and
    /// uploaded later would be "younger" than it is. "The cloud wins" depended on the
    /// side — and was exactly the swap from R1b.
    public static func wins(_ links: Profile.Identifier, about right: Profile.Identifier) -> Bool {
        ProfileTombstone.norm(links) < ProfileTombstone.norm(right)
    }

    /// One profile from both sides — identifier and label (name, color, picture) from above,
    /// accesses from here. Which identifier ends up staying is decided by ``wins(_:about:)``.
    ///
    /// **When two people become a child, the adult brings no unique accesses**
    /// (final check 2026-09-25, N-2). Until then "if one is missing, the other comes" applied:
    /// if the child had no media server, the adult's Jellyfin access flowed into the
    /// result — a child profile with an adult's account, and the barrier that
    /// hangs on the server stood open. The same applies to the server person (`.portals`):
    /// it is an identity and not a wish. Channel lists still come along, they carry
    /// no person. **Only for different identifiers** — equal identifier means: the same
    /// person whose kind was just changed; taking their own access away would be
    /// a loss without protection.
    static func fuse(device: Profile, cloud: Profile) -> Profile {
        var combined = Profile(
            identifier: cloud.identifier,
            name: cloud.name,
            color: cloud.color,
            kind: stricter(cloud.kind, device.kind),
            credentials: [],
            // **The picture belongs to the label and comes from above** — unless above it was
            // never decided (`nil`), then this device's stays. A "No picture"
            // from above (`""`) is a choice and wins.
            avatar: cloud.avatar ?? device.avatar)
        // First the own ones, then those of the cloud: ``ProfileKit/create(_:)`` replaces the
        // one of the same kind, so for a media server access the **last** one
        // laid wins. The cloud should not win here — this house's access is the
        // right one —, so the cloud accesses come only if there is no own one.
        let foreign = device.identifier != cloud.identifier && combined.kind == .kind
        for credential in device.credentials
        where !(foreign && device.kind != .kind && credential.onlyOnce) {
            combined.create(credential)
        }
        for credential in cloud.credentials where !combined.credentials.contains(credential) {
            guard
                !credential.onlyOnce || !combined.credentials.contains(where: { $0.kind == credential.kind })
            else { continue }
            guard !(foreign && cloud.kind != .kind && credential.onlyOnce) else { continue }
            combined.create(credential)
        }
        return combined
    }

    /// The stricter of two kinds.
    static func stricter(_ links: Profile.Kind, _ right: Profile.Kind) -> Profile.Kind {
        links == .kind || right == .kind ? .kind : links
    }

    /// Whether two names mean the same person.
    ///
    /// **Edges and capitalization do not count.** "alex" and "Alex " are the same
    /// input from two keyboards — one on the TV, the other on the phone, and only
    /// one of them capitalizes by itself.
    static func sameName(_ links: String, _ right: String) -> Bool {
        let a = links.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        let b = right.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        return !a.isEmpty && a == b
    }
}
