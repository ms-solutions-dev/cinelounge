import CommonCrypto
import Core
import Foundation
import Security

/// A profile's PIN — **as a salted verification value, with a timestamp, and it travels via
/// iCloud** (AP52, owner decision 12 of 2026-09-25).
///
/// **The finding that makes this type necessary:** until AP52 nobody could set a profile PIN.
/// Bolt (``ProfileSwitch``), keypad, "Forgot PIN" and the PIN requirement when
/// merging were in place, but `Pin(store:forItem:).set` had only checks as callers —
/// and a PIN that was set would have lain only in the Keychain of that one device.
///
/// ## What is stored
///
/// **Never the digits.** A ``Verifier`` made of 16 random bytes of salt and the digest
/// `PBKDF2-HMAC-SHA256(digits, salt, rounds)` — on the device in the Keychain, in the cloud in the
/// dedicated record type ``ProfilePINMapping/contentType``. Both places carry the same thing, and neither can
/// reveal the PIN.
///
/// ## What the digest protects — and what not
///
/// **Honestly:** four digits are 10,000 possibilities. Whoever has the verification value computes them
/// within minutes despite 200,000 rounds; the salt only prevents a precomputed table
/// from helping. So the digest protects **against casual reading** — a glance into a
/// record, a backup, a log — and not against someone who attacks it deliberately.
/// **The actual security is the account's private iCloud database**
/// (and for a shared profile the share its owner granted) as well as the
/// device's Keychain. Salt and digest additionally lie in the cloud in
/// `encryptedValues` (``ProfilePINMapping/isSecret``).
///
/// ## "No PIN" is a value
///
/// **An ``ContentEntryRecord`` with `verifier == nil` is a tombstone** — "the PIN was removed here,
/// at this time". The absence of the entry, by contrast, means "never decided".
/// The lesson from AP49 (B1/B3): whoever sent "gone" as a deletion would lose against any device
/// that still has the old record in its mirror, and the PIN would come back on the next pass.
///
/// ## The younger one wins
///
/// Every entry carries the time it was set (``ContentEntryRecord/time``); ``adopt(_:)`` takes
/// a foreign one only if it is younger, and the zone merges by the same field
/// (``ProfilePINMapping/rule``). Two devices that set against each other offline thereby agree
/// on the later one — alike on both.
///
/// ## Separate from parental controls
///
/// **The device's PIN is ``ParentalControls/Pin`` and stays as it was**: its own
/// key, its own digest, never in the cloud. This type reads and writes only under
/// ``basis`` with the profile identifier and does not touch that one's key.
public struct ProfilePIN: Sendable {

    /// How many digits — the same number as the keypad in the design draft.
    public static let locations = 4

    /// The rounds of the derivation.
    ///
    /// **200,000, because a press on the keypad computes them on the TV in a fraction
    /// of a second** and because more gains nothing with four digits — see above.
    /// The number travels with the verification value (``Verifier/rounds``); a later version can
    /// raise it without old PINs becoming invalid.
    public static let rounds = 200_000

    /// Which number of rounds a verification value may carry — **a narrow range around ``rounds``.**
    ///
    /// **The finding** (review 2026-09-25 evening): `rounds` came unchecked from the cloud's
    /// record, and the derivation runs on the main thread while typing. A record with two
    /// billion rounds froze the TV for hours on every PIN entry. Half to five times the
    /// number leaves a later version headroom upward without any
    /// entry taking noticeably longer; what lies outside is not a verification value.
    public static let roundsRange = (rounds / 2)...(rounds * 5)

    /// How many bytes of salt.
    public static let saltLength = 16

    /// The base key in the Keychain; the per-profile compartment is appended by ``Core/ProfileStore``.
    /// **A different one from that of the device PIN** (`childLock.pinDigest`).
    ///
    /// **Assembled, because `scripts/strings.py` takes every string of the form `a.b` for
    /// a language key.**
    public static let basis = ["profile", "pin"].joined(separator: ".")

    /// Salt, digest and round count — **the only thing that is ever stored of a PIN.**
    public struct Verifier: Sendable, Equatable, Codable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case salt = "salz"
            case digest = "abdruck"
            case rounds = "runden"
        }

        public let salt: Data
        public let digest: Data
        public let rounds: Int

        public init(salt: Data, digest: Data, rounds: Int) {
            self.salt = salt
            self.digest = digest
            self.rounds = rounds
        }
    }

    /// The state of a profile PIN: a verification value **or a tombstone**, the time — and
    /// **which state the device knew when setting it** (``basis``).
    public struct ContentEntryRecord: Sendable, Equatable, Codable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case verifier = "pruefwert"
            case time = "zeit"
            case basis
        }

        /// `nil` means: **the PIN was removed** — not "never set". See above.
        public let verifier: Verifier?
        /// When set or removed — the basis for "the younger one wins".
        public let time: Date
        /// The ``time`` of the entry that lay on the device when this one was created — `nil` if
        /// nothing had ever been decided there.
        ///
        /// **The finding that makes this field necessary** (review 2026-09-25 evening): a device
        /// that had not yet synced the PIN from the cloud saw no lock and
        /// accepted a "first" PIN without an old one — and that one beat the genuine one with its later time,
        /// on every device. A child on the iPad could thus have taken over an adult's profile without
        /// ever knowing its PIN. With the base one can read off whether the setter
        /// **saw** the other state (``overlooks(_:)``).
        public let basis: Date?

        public init(verifier: Verifier?, time: Date, basis: Date? = nil) {
            self.verifier = verifier
            self.time = time
            self.basis = basis
        }

        /// Whether this entry demands a PIN.
        public var isSet: Bool { verifier != nil }

        /// Whether this entry sets a PIN **without having known the PIN of `other`** —
        /// because on setting, nothing at all or an older state lay on the device.
        ///
        /// **Only PIN against PIN.** Whoever sets a PIN on an open profile takes
        /// nothing from anyone, and a tombstone comes about only with the old PIN or via the
        /// way out (``ProfilePINMaintenance``); for both, "the younger one wins" remains.
        public func overlooks(_ other: ContentEntryRecord) -> Bool {
            guard isSet, other.isSet, self != other else { return false }
            guard let basis else { return true }
            return basis < other.time
        }

        /// Whether this entry — **a device's own** — supersedes the cloud's.
        ///
        /// **It must be younger**, and at equal time what is there stays; otherwise
        /// two devices would write the same state back and forth endlessly.
        ///
        /// **And it must not have overlooked the cloud's PIN** (``overlooks(_:)``):
        /// a PIN that was set without knowledge of the one there proves nothing about
        /// the profile and loses — no matter how late its clock ran. The direction is
        /// deliberate: the setter is always the one asked, never the cloud. If two devices
        /// set a first PIN against each other offline, the one that stood in the cloud first
        /// therefore holds; the other never saw it.
        public func resolves(from other: ContentEntryRecord?) -> Bool {
            guard let other else { return true }
            guard !overlooks(other) else { return false }
            return time > other.time
        }
    }

    private let store: any KeyValueStore
    private let identifier: Profile.Identifier

    /// - Parameters:
    ///   - ablage: the device's Keychain (in the checks a compartment of its own).
    ///   - kennung: whose PIN. **No default** — a PIN without a profile is the device's,
    ///     and that is a different type.
    public init(store: any KeyValueStore, forItem identifier: Profile.Identifier) {
        self.store = store
        self.identifier = identifier
    }

    private var key: String { ProfileStore.bucket(Self.basis, forItem: identifier.rawValue) }

    // MARK: - Lesen

    /// The entry on the device — `nil` if nothing was ever decided here.
    public var entry: ContentEntryRecord? {
        guard let raw = try? store.value(for: key), let data = raw.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(ContentEntryRecord.self, from: data)
    }

    /// Whether this profile demands a PIN.
    public var isSet: Bool { entry?.isSet ?? false }

    /// Checks an input against the verification value on the device.
    ///
    /// **The value from the cloud arrives here via ``adopt(_:)``**, and before a
    /// bolt needs it: ``ProfileCloud/download(_:)`` on every pass and every silent
    /// push, ``ProfileCloud/adopt(_:now:)`` for a profile that was only just found.
    /// The verification path therefore reads one place and not two — if nothing lies on the device,
    /// that is the cloud's value as soon as it has been read once.
    ///
    /// **Without a set PIN the answer is `false`** — the same rule as with
    /// ``ParentalControls/Pin/matches(_:)``: a PIN that was not assigned opens nothing. Whoever
    /// asks asks ``isSet`` first.
    public func matches(_ digits: String) -> Bool {
        guard let verifier = entry?.verifier else { return false }
        return Self.matches(digits, against: verifier)
    }

    // MARK: - Schreiben

    /// Sets a new PIN — **without asking for the old one.** That is done by
    /// ``ProfilePINMaintenance``; here is only the storing.
    ///
    /// - Returns: the new entry, or `nil` if the input is not a four-digit
    ///   sequence of digits.
    @discardableResult
    public func set(_ digits: String, now: Date) -> ContentEntryRecord? {
        guard Self.isValid(digits), let verifier = Self.verifier(forItem: digits) else {
            return nil
        }
        let fresh = ContentEntryRecord(verifier: verifier, time: now, basis: entry?.time)
        write(fresh)
        return fresh
    }

    /// Removes the PIN — **as a tombstone with a time, not as a deletion.**
    @discardableResult
    public func remove(now: Date) -> ContentEntryRecord {
        let fresh = ContentEntryRecord(verifier: nil, time: now, basis: entry?.time)
        write(fresh)
        return fresh
    }

    /// Takes over the cloud's entry — **if the own one does not supersede it**
    /// (``ContentEntryRecord/resolves(from:)``).
    ///
    /// **The same question as when pushing up**, just from the other side
    /// (``ProfileCloud/passOnPin(_:from:)``, ``ProfilePINMapping/rule``): what must not go
    /// up there is replaced here. A device that had overlooked a PIN carries afterwards
    /// the cloud's and no longer its own.
    ///
    /// - Returns: whether anything changed on the device.
    @discardableResult
    public func adopt(_ foreign: ContentEntryRecord) -> Bool {
        let here = entry
        guard here != foreign, !(here?.resolves(from: foreign) ?? false) else { return false }
        write(foreign)
        return true
    }

    /// Removes the entry entirely — **only if the profile itself disappears** (removal,
    /// merging). For "no PIN any more" there is ``remove(now:)``.
    public func forget() {
        try? store.remove(key)
    }

    private func write(_ fresh: ContentEntryRecord) {
        guard let data = try? JSONEncoder().encode(fresh),
            let text = String(data: data, encoding: .utf8)
        else { return }
        try? store.set(text, for: key)
    }

    // MARK: - Ableitung

    /// Whether an input has the form of a PIN — four digits and only digits.
    public static func isValid(_ digits: String) -> Bool {
        digits.count == locations && digits.allSatisfy { ("0"..."9").contains($0) }
    }

    /// A fresh verification value — **with new salt on every set.** The same PIN set
    /// twice yields two different values; whoever compares two records does not learn
    /// whether the PIN stayed the same.
    static func verifier(forItem digits: String) -> Verifier? {
        var salt = Data(count: saltLength)
        let result = salt.withUnsafeMutableBytes { pointer -> OSStatus in
            guard let start = pointer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, saltLength, start)
        }
        guard result == errSecSuccess,
            let digest = derive(digits, salt: salt, rounds: rounds)
        else { return nil }
        return Verifier(salt: salt, digest: digest, rounds: rounds)
    }

    /// Compares an input with a verification value — **in constant time**, the same line as with
    /// the device PIN: with four digits a timing attack is theory, but the exception
    /// would have to be justified.
    public static func matches(_ digits: String, against verifier: Verifier) -> Bool {
        guard isValid(digits), roundsRange.contains(verifier.rounds),
            let input = derive(digits, salt: verifier.salt, rounds: verifier.rounds),
            input.count == verifier.digest.count
        else { return false }
        var difference: UInt8 = 0
        for (links, right) in zip(input, verifier.digest) { difference |= links ^ right }
        return difference == 0
    }

    /// PBKDF2-HMAC-SHA256 via CommonCrypto — **32 bytes of digest.**
    static func derive(_ digits: String, salt: Data, rounds: Int) -> Data? {
        let password = Array(digits.utf8).map { CChar(bitPattern: $0) }
        var digest = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
        let length = digest.count
        let status = digest.withUnsafeMutableBytes { target in
            salt.withUnsafeBytes { salzzeiger in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2), password, password.count,
                    salzzeiger.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds),
                    target.bindMemory(to: UInt8.self).baseAddress, length)
            }
        }
        return status == kCCSuccess ? digest : nil
    }
}
