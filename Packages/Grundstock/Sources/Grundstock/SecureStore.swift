import Foundation
import Security

/// Store for credentials in the device's Keychain.
///
/// Deliberately not in the ordinary settings: there, password and
/// access token would sit in plain text in a file that every backup takes along. The
/// Keychain encrypts them.
///
/// **What also stood here until 2026-09-07 was wrong** (AP10 of the phone project):
/// "…and binds them to the device." It does **not** do that, at least not with the
/// access class set further below. `kSecAttrAccessibleAfterFirstUnlock`
/// without `ThisDeviceOnly` migrates into the encrypted backup and can be restored on
/// a **different** device — server access, provider password and the
/// PIN digest of the parental controls included.
///
/// The sentence was right compared with the ordinary settings (where everything is in
/// plain text) and was not right as a statement about the device.
///
/// **The class stays nevertheless, and with a reason.** As long as the device handoff
/// is not wired up, restoring from a backup is the **only** way
/// onto a new phone; `ThisDeviceOnly` would take it away and put nothing in its place.
/// It is switched over on the day the handoff is in place — the weighing, with all three
/// counter-checks, is in `jellyfin-tvos/Phone/entwuerfe/ENTSCHEIDUNGEN.md`.
///
/// **State 2026-09-27 (AP54):** The handoff is in place. The keys that *identify* a
/// device have been switched over (``init(service:accessGroup:thisDeviceOnly:)``); accesses and passwords
/// stay with this class, because the handoff brings them only to the TV and not
/// to a new phone.
///
/// **What really mattered here has long been right:** `kSecAttrSynchronizable` is set
/// nowhere. There is no ongoing sync via iCloud — the keychain lies on this device
/// and in its backup, nowhere else.
///
/// Also needed by the channel lists — accesses by the Xtream method
/// consist of username and password.
public struct SecureStore: Sendable {

    public enum Failure: Error, Equatable {
        case notFound
        /// The Keychain refused. The number is the system's error code.
        case denied(OSStatus)
        case malformed
    }

    private let service: String

    /// Set only for entries that app and extension **share** — then
    /// they lie in the Keychain group of the app group instead of in the target's own
    /// area. A `nil` changes nothing about the previous behavior.
    private let accessGroup: String?

    /// Entries that are **bound to this device** and do not migrate to another one via a backup
    /// (`…ThisDeviceOnly`).
    ///
    /// Intended for keys that *identify* a device — the pairing credentials of the
    /// remote (2026-09-27, AP54). If they migrated along, a device restored from a backup
    /// would pass itself off as the old one until someone pairs anew. Accesses and
    /// passwords stay with the old class: for them the backup is an intended way
    /// onto a new device.
    ///
    /// Entries that still lie with the old class are moved over by ``value(for:)`` on the first
    /// read — without the caller knowing.
    private let thisDeviceOnly: Bool

    public init(
        service: String = AppBundleIdentifiers.bundles, accessGroup: String? = nil,
        thisDeviceOnly: Bool = false
    ) {
        self.service = service
        self.accessGroup = accessGroup
        self.thisDeviceOnly = thisDeviceOnly
    }

    /// Readable after the first unlock, so that the app also gets the access token
    /// when launched in the background; with ``thisDeviceOnly`` additionally bound to the device.
    var accessClass: CFString {
        thisDeviceOnly
            ? kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly : kSecAttrAccessibleAfterFirstUnlock
    }

    /// The shared components of every query.
    private func query(for key: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    public func set(_ value: String, for key: String) throws {
        guard let data = value.data(using: .utf8) else { throw Failure.malformed }

        // Delete first, then write anew. An in-place update
        // would be a second path with its own failure cases, without gain.
        try? remove(key)

        var query = query(for: key)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = accessClass

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.denied(status) }
    }

    public func value(for key: String) throws -> String {
        var query = query(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                let string = String(data: data, encoding: .utf8)
            else { throw Failure.malformed }
            if thisDeviceOnly { bind(key) }
            return string
        case errSecItemNotFound:
            throw Failure.notFound
        default:
            throw Failure.denied(status)
        }
    }

    /// Moves an entry to the device-bound class. If it already lies there, nothing
    /// changes; if it fails, it stays readable as before and the next read
    /// tries again.
    private func bind(_ key: String) {
        _ = SecItemUpdate(
            query(for: key) as CFDictionary,
            [kSecAttrAccessible as String: accessClass] as CFDictionary)
    }

    public func remove(_ key: String) throws {
        let status = SecItemDelete(query(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure.denied(status)
        }
    }

    public func contains(_ key: String) -> Bool {
        (try? value(for: key)) != nil
    }
}
