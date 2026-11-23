import Core
import Foundation

/// The limit per account — **five levels and "no limit".**
///
/// **The levels are those of the design and those of the FSK** (German age ratings): 0,
/// 6, 12, 16, 18. A free-form number would be more precise and useless: no server
/// delivers "from 14", and a limit that exists in no rating separates nothing.
///
/// **"No limit" is `nil` and not a sixth level.** It is the absence of a limit, not a
/// particularly high one — and the difference matters: with "no limit" nothing is
/// filtered at all, not even what is not understood. A level "99" would have kept
/// filtering while removing nothing, which looks like the same thing and is not the same
/// thing.
public enum AgeLimit: Int, Sendable, Equatable, CaseIterable, Codable {
    /// Stored case names keep their original (German) form — renaming them would
    /// make data written by earlier versions unreadable (AP85 B4).
    private enum CodingKeys: String, CodingKey {
        case from0 = "ab0"
        case from6 = "ab6"
        case from12 = "ab12"
        case from16 = "ab16"
        case from18 = "ab18"
    }

    case from0 = 0
    case from6 = 6
    case from12 = 12
    case from16 = 16
    case from18 = 18

    /// Whether a title with this rating is let through.
    ///
    /// **Equal is allowed.** "From 12" with a limit of 12 is exactly what the parent
    /// configured — anyone who wrote `<` here would shift every limit by one level, and
    /// nobody would find the reason.
    public func letsPass(_ approval: Int) -> Bool { approval <= rawValue }

    /// The label on the chip — **a number, not a sentence.**
    public var caption: String { String(rawValue) }
}

// MARK: - Ablage

/// **Where the limit lives is exactly here** — and nowhere else.
///
/// **The finding of 10.09.2026 (AP22):** The key existed in two places, and the two places
/// did not mean the same store. The takeover from the phone wrote it as an `Int` into
/// `UserDefaults`, the TV side read it as a string from the Keychain. The PIN arrived â
/// both sides Keychain. Child mode arrived — both sides `UserDefaults`. **The limit did
/// not.** Afterwards the TV showed: child mode on, PIN set, no limit — and
/// ``ProtectionRule/shows(approval:)`` lets everything through without a limit. The
/// filter ran and filtered nothing, without reporting it.
///
/// **That is why key, type and both directions live together.** Two callers that spell
/// the same key themselves can disagree about its type; two callers of the same method
/// cannot.
extension AgeLimit {

    /// **The same key as in the phone project**, literally. Anyone who invented their own
    /// here would write to a place nobody reads.
    ///
    /// **Not a language key but a store key** — `scripts/strings.py` recognises this by the
    /// namespace `childLock.`.
    public static let storeKey = "childLock.ageLimit"

    /// The stored limit. `nil` means **no limit**.
    ///
    /// **Read as an optional number and not as an `Int` with a default of 0.** Turning a
    /// missing value into a 0 would have serious consequences: 0 is a **level** ("from 0")
    /// and not "no limit" — the difference is that between "everything locked except FSK 0"
    /// and "not locked at all".
    ///
    /// **An unknown number also yields `nil`.** "From 14" does not exist (see above); whatever
    /// is stored there comes from a foreign or broken store, and an invented neighbouring
    /// level would be an assertion.
    /// - Parameter profil: Whose limit. `nil` is that of the **device** — the device
    ///   baseline from ``ProfileSlot``, and it stays, because "the TV in the children's
    ///   room" is a statement of its own.
    public static func read(
        from store: any KeyValueStore, forItem profile: String? = nil
    ) -> AgeLimit? {
        let key = ProfileSlot.key(storeKey, forItem: profile)
        guard let raw = try? store.value(for: key), let number = Int(raw) else {
            return nil
        }
        return AgeLimit(rawValue: number)
    }

    /// Stores the limit. `nil` withdraws it.
    ///
    /// **Withdrawing means deleting and not "setting to 18".** "From 18" is a level that
    /// locks something; "no limit" is the absence of the question. Anyone who merged the two
    /// could no longer say afterwards what had been configured.
    public static func write(
        _ limit: AgeLimit?, in store: any KeyValueStore, forItem profile: String? = nil
    ) {
        let key = ProfileSlot.key(storeKey, forItem: profile)
        if let limit {
            try? store.set(String(limit.rawValue), for: key)
        } else {
            try? store.remove(key)
        }
    }
}

extension AgeLimit {

    /// The limit that applies to **this person on this device** — the **stricter** of
    /// profile and device baseline.
    ///
    /// **The sentence was already there, the computation was not** (AP45, 2026-09-24).
    /// ``ProfileKit/ProtectionRule/forItem(_:deviceLocked:keychain:)`` promises in its
    /// DocC "the stricter of the two applies — person and device", and
    /// ``ParentalControls/ProtectionRule/applies`` does combine device lock and account type
    /// with OR. The **limit**, however, was read in only one of the two places: whoever passed
    /// `forItem:` got the profile's and **lost the device's**; whoever left it out got the
    /// device's for everyone.
    ///
    /// **And without this computation every refactoring was a trap.** The only screen that
    /// sets a limit (``ParentalControlsView``) writes it to the **device** — it knows no
    /// profile. Had the state been read per profile alone, every limit set there would have
    /// become ineffective, without a message.
    ///
    /// **Stricter means smaller.** "From 6" locks more than "from 18"; `nil` means "no
    /// question" and therefore loses against any number. Two `nil` stay `nil`.
    public static func forItem(
        profile own: AgeLimit?, device base: AgeLimit?
    ) -> AgeLimit? {
        switch (own, base) {
        case (nil, nil): nil
        case (let only?, nil): only
        case (nil, let only?): only
        case (let a?, let b?): a.rawValue <= b.rawValue ? a : b
        }
    }

    /// The same question, read directly from the store.
    ///
    /// **A separate path and not `read(from:forItem:)` with an addition**, because the two
    /// questions differ: "What has this person configured?" is what the settings view needs,
    /// "what applies to them now?" is what the filter needs. Anyone who merged the two could
    /// no longer show in the view what is really stored there.
    public static func applicable(
        from store: any KeyValueStore, forItem profile: String?
    ) -> AgeLimit? {
        forItem(
            profile: profile.flatMap { read(from: store, forItem: $0) },
            device: read(from: store, forItem: nil))
    }
}
