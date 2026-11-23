import Core
import CryptoKit
import Foundation

/// The person token of the CineLounge server — **the key with which every further own
/// device of a person signs itself in** (AP47).
///
/// **A type of its own and not a string**, because it is a secret: whoever has it signs
/// devices in as this person. Swift writes a value out by itself in three ways —
/// `description`, `debugDescription` and the mirror for `dump` —, and all three are
/// blocked here. A log line `"\(tag)"` therefore betrays nothing, and someone will write
/// exactly this line sometime.
///
/// **Not `Codable`, on purpose.** A `Codable` secret ends up, at the first convenient
/// grab, in a file or in a bundle that travels over the unsecured wire of the second screen
/// (``ProfileKit`` travels there as JSON). It is stored only via ``PortalMarkerSlot`` in the
/// Keychain and, encrypted, via ``PortalMarkerMapping`` in the zone.
public struct PersonMarker: Sendable, Equatable, Hashable {

    /// The wording for `POST /device/enroll`. Read only there.
    public let value: String

    /// - Returns: `nil` for an empty token — an empty string is not a token,
    ///   and with it `/device/enroll` could only fail.
    public init?(value: String) {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        self.value = clean
    }

    /// A digest of the token — **to know whether it is the same without keeping it twice.**
    ///
    /// Self-enrollment remembers which token this device came in with and which one it failed
    /// on. If the token itself were stored there, the secret would sit in three places instead
    /// of one; a SHA-256 of it says "same or not" and nothing else.
    public var digest: String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

extension PersonMarker: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "Personenmarke(•••)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

/// Where a profile's person token lies **on this device** — in the Keychain, one slot per
/// profile.
///
/// **Product decision (A) of 2026-09-24: the token is part of the profile.** This means:
/// it travels with the profile via CloudKit, also into a shared profile — "sharing a profile
/// means sharing all of it". ``PortalMarkerMapping`` does that in the profile's zone.
/// **On the device it still does not lie in the ``ProfileKit`` value, and that is a weighed
/// decision:**
///
/// - ``ProfileKit`` is `Codable` and goes as plain text into the ``ProfileBook`` file and into the
///   setup bundle of the second screen, whose wire in the home network runs **without TLS**. The
///   header text of that bundle says "Without secrets"; a field on the profile would break that
///   silently.
/// - ``Access`` explicitly carries only identifiers, "password and access token stay in the
///   Keychain". A case `portals(person:tag:)` would moreover have broken every
///   `case .portals(let person)` site of the iPhone app.
///
/// The slot follows the pattern of the playback preferences (``Core/ProfileStore``): the same
/// key with the profile ID at the end, in the same store. **Additive:** a profile
/// without a slot has no token, and nothing about ``ProfileKit`` changes.
public struct PortalMarkerSlot: Sendable {

    /// The key stem. **Not a language key** — the namespace `join` does not occur in the
    /// language catalog, and so `scripts/strings.py` does not mistake it for one.
    public static let stem = "beitritt.personenmarke"

    private let keychain: any KeyValueStore

    /// - Parameter schluesselbund: in the program ``Core/SecureStore``; the checks
    ///   pass in an in-memory store.
    public init(_ keychain: any KeyValueStore) {
        self.keychain = keychain
    }

    static func key(_ identifier: Profile.Identifier) -> String {
        ProfileStore.bucket(stem, forItem: identifier.rawValue)
    }

    /// This profile's token, or `nil` — also for every child profile: a child
    /// gets none from the server.
    public func tag(forItem identifier: Profile.Identifier) -> PersonMarker? {
        guard let value = try? keychain.value(for: Self.key(identifier)) else {
            return nil
        }
        return PersonMarker(value: value)
    }

    /// Stores the token.
    ///
    /// - Returns: whether anything changed — only then does the caller trigger a sync.
    @discardableResult
    public func create(_ tag: PersonMarker, forItem identifier: Profile.Identifier) -> Bool {
        guard self.tag(forItem: identifier) != tag else { return false }
        try? keychain.set(tag.value, for: Self.key(identifier))
        return true
    }

    /// Clears the slot — **when the profile no longer exists on this device.**
    public func forget(forItem identifier: Profile.Identifier) {
        try? keychain.remove(Self.key(identifier))
    }

    /// Carries along the token of a migrated ID (``ProfileSync``).
    ///
    /// **Only into an empty slot.** If the target already has a token, it came from the cloud and
    /// is the newer information; the local one would otherwise have silently overwritten a change
    /// from another device.
    public func migrate(from old: Profile.Identifier, to fresh: Profile.Identifier) {
        guard old != fresh, let tag = tag(forItem: old) else { return }
        if self.tag(forItem: fresh) == nil { create(tag, forItem: fresh) }
        forget(forItem: old)
    }
}
