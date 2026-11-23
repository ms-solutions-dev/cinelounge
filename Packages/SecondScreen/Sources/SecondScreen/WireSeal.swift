import CryptoKit
import Foundation

/// AES-GCM over a key — **the one building block on which handoff and remote
/// both sit** (2026-09-25).
///
/// **Extracted from ``HandoffPackage`` when the remote got the same pairing**
/// (decision 6). Two copies of the same three lines would be two places where
/// a detail — such as the question of what a failed opening reveals — quietly
/// drifts apart.
///
/// **Opening reveals nothing.** A wrong key, a tampered packet and a
/// truncated packet all give the same `nil`: What the crypto library says about it
/// is information about content that is currently **not** trustworthy.
enum WireSeal {

    static func seal(_ plainText: Data, using key: SymmetricKey) throws -> Data {
        guard let merged = try AES.GCM.seal(plainText, using: key).combined else {
            throw CryptoKitError.incorrectParameterSize
        }
        return merged
    }

    static func open(_ data: Data, using key: SymmetricKey) -> Data? {
        guard let box = try? AES.GCM.SealedBox(combined: data) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }
}
