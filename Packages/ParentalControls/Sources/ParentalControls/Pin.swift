import Core
import CryptoKit
import Diagnose
import Foundation

/// The PIN — **in the Keychain and as a digest, not in plain text.**
///
/// **Four digits, because the design draws it that way** and because a PIN is entered
/// standing up with one thumb. Longer would be more secure and would be used less often; a
/// lock that people bypass because it is annoying locks nothing.
///
/// **What is stored is a digest and not the digits.** The Keychain is secure, and still:
/// there is no reason to hold four digits in plain text that are also used elsewhere â
/// people use the same PIN for everything. The digest is what gets compared.
///
/// **With a salt, and the salt lies next to it.** Without a salt the digest of "1234" would be
/// the same on every device, and a list of the ten thousand possibilities is computed in a
/// second. With a salt per device it is useless. A slow method (PBKDF2, scrypt) would be even
/// better and is not available here without bringing in a library — that stands here as a
/// **known limit** and not as an oversight: whoever has this phone's Keychain open has more
/// than the PIN anyway.
///
/// **It is not on the server and applies only here.** On a second device it is assigned anew
/// â that is what the design says, and it is the honest version: a PIN that travelled along
/// would have to go through a server that not everyone has.
/// **No `Equatable`.** Two accesses to the same Keychain are the same, and two to different
/// ones are not — both would be a comparison over a state that does not live in this
/// structure.
public struct Pin: Sendable {

    /// How many digits. **A number and not a range** — the design's keypad has four fields, and a
    /// PIN whose length you have to guess has none.
    public static let locations = 4

    private static let digestKey = "childLock.pinDigest"
    private static let saltKey = "childLock.pinSalt"
    private static let changedKey = "childLock.pinChanged"

    private let store: any KeyValueStore

    /// **Only the device's PIN now** (AP52, 2026-09-25).
    ///
    /// **Until AP52 this type carried two kinds**, distinguished by a parameter `forItem profile:`
    /// with a default of `nil`: the device PIN, which opens the locked doors and the device
    /// baseline, and the **profile** PIN, which locks entering a profile. Two tasks, two keys â
    /// but one type, and a forgotten ID silently turned a profile PIN into the household's.
    ///
    /// **The profile PIN has been a type of its own since** (``ProfileKit/ProfilePIN``): salted with
    /// PBKDF2, with timestamp and tombstone, and it travels via iCloud. The device PIN stays as
    /// it was — same keys, same digest, **never in the cloud**. A parameter that can address both
    /// no longer exists; the translator checks the separation.
    public init(store: any KeyValueStore) {
        self.store = store
    }

    private func key(_ basis: String) -> String { basis }

    /// Whether a PIN has been assigned at all.
    ///
    /// **Without a PIN there are no parental controls** — and no screen that pretends so. A
    /// switch "turned on" without a stored PIN would be the most serious finding of the pass
    /// again.
    public var isSet: Bool { digest != nil }

    /// When it was last changed — for the row in the sheet.
    public var changed: Date? {
        guard let raw = try? store.value(for: key(Self.changedKey)),
            let seconds = Double(raw)
        else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Sets a new PIN.
    ///
    /// - Returns: `false` if the input is not a four-digit sequence of digits. **Not a thrown
    ///   error**: this is not an exceptional situation but an input that is not finished yet.
    @discardableResult
    public func set(_ digits: String) -> Bool {
        guard Self.isValid(digits) else { return false }
        let salt = Self.newSalt()
        try? store.set(salt, for: key(Self.saltKey))
        try? store.set(Self.digest(from: digits, salt: salt), for: key(Self.digestKey))
        try? store.set(
            String(Date().timeIntervalSince1970), for: key(Self.changedKey))
        return true
    }

    /// Checks an input.
    ///
    /// **Without a set PIN the answer is `false` and not `true`.** An unassigned PIN must not
    /// open any door — otherwise the lock would stand open as soon as someone switches it on
    /// without assigning one.
    public func matches(_ digits: String) -> Bool {
        guard let digest, let salt = try? store.value(for: key(Self.saltKey)) else {
            Diagnose.hint(.parentalControls, "PIN lock: check without a PIN set")
            return false
        }
        // **Constant-time comparison.** With four digits a timing attack is theory; the line costs
        // nothing and the exception would have to be justified.
        let input = Self.digest(from: digits, salt: salt)
        var correct = input.count == digest.count
        if correct {
            for (links, right) in zip(input, digest) where links != right { correct = false }
        }
        // **Not the digits, only the result.** A wrong PIN is the line a parent looks for in the log
        // when "the PIN doesn't work"; the digits themselves do not belong there.
        if !correct {
            Diagnose.hint(.parentalControls, "PIN lock: wrong entry")
        }
        return correct
    }

    /// Withdraws the PIN — **and with it the salt and the date.**
    ///
    /// A leftover salt would reveal that a PIN once existed; that is no harm, but no reason to
    /// keep it either.
    public func delete() {
        for basis in [Self.digestKey, Self.saltKey, Self.changedKey] {
            try? store.remove(key(basis))
        }
    }

    /// Whether an input has the form of a PIN.
    ///
    /// **Digits and only digits.** The design's keypad cannot send anything else; the check is
    /// here anyway, because a keyboard could.
    public static func isValid(_ digits: String) -> Bool {
        digits.count == locations && digits.allSatisfy(\.isNumber)
    }

    private var digest: String? {
        let raw = try? store.value(for: key(Self.digestKey))
        return (raw?.isEmpty ?? true) ? nil : raw
    }

    // MARK: - Move to another device

    /// What travels along from a PIN when a phone sets up a TV.
    ///
    /// **Digest and salt, not the digits** — and that is not caution but the only possibility:
    /// the four digits exist nowhere. They are salted and hashed when set and afterwards only
    /// compared; a device cannot name its own PIN.
    ///
    /// **Found while building the handoff channel** (10.09.): ``SetupBundle`` carried a
    /// field `pin: String` until then, and nobody could have filled it. A bundle with an empty
    /// field would have arrived at the TV as "parental controls without a PIN" — the most
    /// serious finding of the usability pass again, this time on a second device.
    public struct Extract: Sendable, Equatable, Codable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case digest = "abdruck"
            case salt = "salz"
            case changed = "geaendert"
        }

        public let digest: String
        public let salt: String
        public let changed: Date?

        public init(digest: String, salt: String, changed: Date?) {
            self.digest = digest
            self.salt = salt
            self.changed = changed
        }
    }

    /// This PIN's extract — `nil` if none is assigned.
    public var extract: Extract? {
        guard let digest, let salt = try? store.value(for: key(Self.saltKey)), !salt.isEmpty
        else { return nil }
        return Extract(digest: digest, salt: salt, changed: changed)
    }

    /// Takes over a PIN from another device.
    ///
    /// **The same salt and the same digest**, otherwise the new device would check against a
    /// different value and reject the correct PIN. The change date travels along, because the row
    /// in the sheet would otherwise say "never changed" although it was.
    public func adopt(_ extract: Extract) {
        try? store.set(extract.salt, for: key(Self.saltKey))
        try? store.set(extract.digest, for: key(Self.digestKey))
        if let changed = extract.changed {
            try? store.set(
                String(changed.timeIntervalSince1970), for: key(Self.changedKey))
        }
    }

    private static func newSalt() -> String {
        UUID().uuidString
    }

    static func digest(from digits: String, salt: String) -> String {
        let data = Data((salt + digits).utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
