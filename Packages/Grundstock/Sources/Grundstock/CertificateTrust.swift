import CryptoKit
import Foundation
import Security

/// The fingerprint of a certificate — the short checksum by which a
/// certificate can be recognized without storing it in full.
public struct CertificateFingerprint: Sendable, Equatable, Hashable, Codable {

    /// The checksum in hexadecimal notation, without separators.
    public let value: String

    public init(value: String) {
        self.value = value.uppercased()
    }

    /// Computes the fingerprint from the raw data of a certificate.
    public init(certificateData: Data) {
        let digest = SHA256.hash(data: certificateData)
        self.value = digest.map { String(format: "%02X", $0) }.joined()
    }

    /// Wrapped into groups of four characters for display on the TV.
    ///
    /// A fingerprint in one piece cannot be compared from three meters away with what
    /// is on the computer — and that comparison is the whole point.
    public var readable: String {
        stride(from: 0, to: value.count, by: 4)
            .map { offset -> String in
                let start = value.index(value.startIndex, offsetBy: offset)
                let end = value.index(start, offsetBy: min(4, value.count - offset))
                return String(value[start..<end])
            }
            .joined(separator: " ")
    }

    /// The first groups — enough for a glance when no comparison is pending.
    public var short: String {
        readable.split(separator: " ").prefix(4).joined(separator: " ") + " …"
    }
}

/// Remembers which certificates have been trusted for which server.
///
/// The method is the same one SSH has used for decades: on first
/// contact the fingerprint is shown and confirmed once, after that only
/// exactly this certificate counts. If it changes, there is a warning instead of
/// silent acceptance.
///
/// The difference from "accept all certificates" is essential: an
/// attacker on the same network could otherwise slip in unnoticed.
/// Here they would be noticed immediately, because their certificate would have a different
/// fingerprint.
public struct CertificateTrustStore: Sendable {

    private let store: any KeyValueStore
    private static let key = "trusted.certificates"

    public init(store: any KeyValueStore = SecureStore()) {
        self.store = store
    }

    /// Mapping from server name to confirmed fingerprint.
    public func trusted() -> [String: CertificateFingerprint] {
        guard let json = try? store.value(for: Self.key),
            let data = json.data(using: .utf8),
            let map = try? JSONDecoder().decode([String: CertificateFingerprint].self, from: data)
        else { return [:] }
        return map
    }

    public func fingerprint(for host: String) -> CertificateFingerprint? {
        trusted()[host.lowercased()]
    }

    /// What to do when a connection is established.
    public enum Decision: Equatable {
        /// Known and unchanged — pass.
        case accept
        /// Never seen before. The user must confirm the fingerprint.
        case askUser(CertificateFingerprint)
        /// Known, but **different** from last time. This is the serious
        /// case: either the certificate was renewed, or someone is interposing
        /// themselves. Never accept silently.
        case changed(known: CertificateFingerprint, presented: CertificateFingerprint)
    }

    public func evaluate(_ presented: CertificateFingerprint, for host: String) -> Decision {
        guard let known = fingerprint(for: host) else {
            return .askUser(presented)
        }
        return known == presented ? .accept : .changed(known: known, presented: presented)
    }

    public func trust(_ fingerprint: CertificateFingerprint, for host: String) throws {
        var map = trusted()
        map[host.lowercased()] = fingerprint
        let data = try JSONEncoder().encode(map)
        guard let json = String(data: data, encoding: .utf8) else { throw SecureStore.Failure.malformed }
        try store.set(json, for: Self.key)
    }

    public func forget(_ host: String) throws {
        var map = trusted()
        map.removeValue(forKey: host.lowercased())
        let data = try JSONEncoder().encode(map)
        guard let json = String(data: data, encoding: .utf8) else { throw SecureStore.Failure.malformed }
        try store.set(json, for: Self.key)
    }
}
