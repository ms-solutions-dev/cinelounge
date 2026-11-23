import CryptoKit
import Foundation

/// The one-time key from the QR code.
///
/// **The QR code authenticates itself.** Whoever sees the screen is standing in front of
/// it — proximity and intent are thereby established, and no second confirmation step is
/// needed. That is why this path comes before iCloud: iCloud asks about the account, the
/// QR code asks about the person in the room.
///
/// **Three minutes and once.** A code that stays on a TV while nobody is in the room is no
/// longer proof of proximity — it is a note on the door. And once, because a second
/// recipient is nothing the first one would ever learn about.
public struct HandoffKey: Sendable, Equatable {

    /// How long a code is valid.
    ///
    /// **Three minutes**: long enough to fetch the phone, and short enough that a forgotten
    /// screen releases nothing any more. The TV shows the code for as long as it is valid, and
    /// a new one afterwards — no expired code stays on screen.
    public static let validity: TimeInterval = 180

    /// The key itself — 32 random bytes.
    public let secret: Data
    /// Where the bundle goes.
    public let target: String
    public let issuedAt: Date

    public init(secret: Data, target: String, issuedAt: Date = Date()) {
        self.secret = secret
        self.target = target
        self.issuedAt = issuedAt
    }

    /// A fresh key.
    public static func fresh(target: String, now: Date = Date()) -> HandoffKey {
        HandoffKey(
            secret: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) },
            target: target, issuedAt: now)
    }

    public func applies(um time: Date = Date()) -> Bool {
        time.timeIntervalSince(issuedAt) < Self.validity
            && time.timeIntervalSince(issuedAt) >= -1
    }

    /// The remaining time in seconds — for the clock on the TV.
    public func remainingTime(um time: Date = Date()) -> TimeInterval {
        max(0, Self.validity - time.timeIntervalSince(issuedAt))
    }

    // MARK: - Als QR-Text

    /// The text that is in the QR code.
    ///
    /// **A custom scheme and not an address.** `https://…` would be read by every camera
    /// window as a web address and opened in a browser; there is nothing there, and the viewer
    /// thinks the code is broken. A custom scheme is not even offered by foreign readers — and
    /// that is right here: exactly one app reads this code.
    public static let schema = "cinelounge-uebergabe"

    public var asText: String { asText(schema: Self.schema) }

    /// The same text under a different scheme — **the pairing of the remote**
    /// (``RemotePairing/schema``) takes the same key but its own code, so that the phone
    /// recognises from the scan what it is about and does not start a handoff.
    public func asText(schema: String) -> String {
        "\(schema)://\(target)?k=\(secret.base64EncodedString())"
    }

    /// Reads a scanned text back.
    ///
    /// **`nil` for everything that does not fit** — and that is the normal case: a camera
    /// sees packaging, posters and Wi-Fi codes. A reader that accepts any of that reports a
    /// failure where nothing was even attempted.
    public static func fromText(_ text: String, now: Date = Date()) -> HandoffKey? {
        fromText(text, schema: schema, now: now)
    }

    /// Reads a text under a particular scheme — see ``asText(schema:)``.
    public static func fromText(
        _ text: String, schema: String, now: Date = Date()
    ) -> HandoffKey? {
        guard let split = URLComponents(string: text), split.scheme == schema,
            let target = split.host, !target.isEmpty,
            let raw = split.queryItems?.first(where: { $0.name == "k" })?.value,
            let secret = Data(base64Encoded: raw), secret.count == 32
        else { return nil }
        return HandoffKey(secret: secret, target: target, issuedAt: now)
    }
}

/// Encrypts and decrypts a bundle.
///
/// **With the one-time key and nothing else.** The channel runs through the home network,
/// and a home network is not a safe place: a second device in it listens in. What goes out
/// here are access tokens and passwords — sending them unencrypted would mean the whole
/// effort with Face ID and the one-time key was for nothing.
public enum HandoffPackage {

    public enum TestError: Error, Equatable {
        case unreadable
        case wrongVersion(Int)
    }

    public static func seal(
        _ bundles: SetupBundle, using key: HandoffKey
    ) throws -> Data {
        let plainText = try JSONEncoder().encode(bundles)
        do {
            return try WireSeal.seal(plainText, using: SymmetricKey(data: key.secret))
        } catch {
            throw TestError.unreadable
        }
    }

    public static func open(
        _ data: Data, using key: HandoffKey
    ) throws -> SetupBundle {
        guard
            let plainText = WireSeal.open(data, using: SymmetricKey(data: key.secret))
        else { throw TestError.unreadable }
        let bundles = try JSONDecoder().decode(SetupBundle.self, from: plainText)
        // **The version is checked after decryption and not before.** It sits in the bundle and
        // not in the envelope: what sits on the outside can be changed by anyone.
        guard SetupBundle.acceptable(version: bundles.version) else {
            throw TestError.wrongVersion(bundles.version)
        }
        return bundles
    }
}
