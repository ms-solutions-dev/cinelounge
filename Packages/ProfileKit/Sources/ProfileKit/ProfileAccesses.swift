import Core
import Foundation

/// Store and remove access of the **active** profile — **from the shell.**
///
/// **The sentence AP41 line 6 is about: access is created where it is
/// set up.** Before, there was an intermediate copy for this: ``Core/AccountState`` remembered in the
/// Keychain whether a media server, a list and the portals exist, and
/// ``RootView`` caught it up on every redraw. An intermediate copy that someone has to
/// catch up is a second truth with a delay — and it only knew the device, never the person.
///
/// **Now the profile carries it directly:** The login stores the media-server access,
/// the accepted channel list its own, the portal switch its own. There is nothing left to
/// catch up, and ``ProfileBook/state`` is not a copy but the question to the thing
/// itself.
///
/// **Read, change, write — and not pass a book around.** The callers are
/// holders in the shell that do not know each other; letting each hold a copy of its own
/// would mean the last one written wins.
public enum ProfileAccesses {

    /// Stores an access with the active profile.
    ///
    /// **Without a profile nothing happens, and that is not a failure.** Before the first
    /// setup there is none; the startup creates it as soon as there is something to create.
    ///
    /// - Returns: whether something was stored.
    @discardableResult
    public static func create(_ credential: Access, in store: any KeyValueStore) -> Bool {
        update(in: store) { $0.create(credential) }
    }

    /// Removes an access from the active profile.
    @discardableResult
    public static func remove(_ credential: Access, in store: any KeyValueStore) -> Bool {
        update(in: store) { $0.remove(credential) }
    }

    /// Removes every access of this kind from the active profile.
    ///
    /// **For signing out:** The caller may no longer know which media-server access was stored
    /// there — the credentials are already deleted by then.
    @discardableResult
    public static func removeAll(_ kind: Access.Kind, in store: any KeyValueStore) -> Bool {
        update(in: store) { profile in
            for credential in profile.credentials where credential.kind == kind { profile.remove(credential) }
        }
    }

    /// Removes an access from **all** profiles.
    ///
    /// **For what disappears from the device, and not for what someone no longer
    /// wants.** A deleted channel list no longer exists — leaving it with the other
    /// profiles would mean keeping a pointer to nothing there, and the
    /// UI would count an access that nobody can open anymore.
    ///
    /// - Returns: whether something changed.
    @discardableResult
    public static func removeEverywhere(
        _ credential: Access, in store: any KeyValueStore
    )
        -> Bool
    {
        removeEverywhere(in: store) { $0 == credential }
    }

    /// Removes an account's media-server access from **all** profiles.
    ///
    /// **Via the account ID (`server|user`) and not via the whole case.** The
    /// display name is in the access because otherwise nobody knows it anymore — it may have changed since
    /// creation, and an account that disappears from the device must not
    /// stay with a profile because of a rename.
    ///
    /// - Returns: whether something changed.
    @discardableResult
    public static func removeMediaServer(
        identifier: String, in store: any KeyValueStore
    )
        -> Bool
    {
        removeEverywhere(in: store) { $0.legacyAccountID == identifier }
    }

    private static func removeEverywhere(
        in store: any KeyValueStore, _ hits: (Access) -> Bool
    ) -> Bool {
        var ledger = ProfileBook.read(from: store)
        let previous = ledger.profile
        for profile in ledger.profile {
            ledger.update(profile.identifier) { person in
                for credential in person.credentials where hits(credential) { person.remove(credential) }
            }
        }
        guard ledger.profile != previous else { return false }
        ledger.write(in: store)
        return true
    }

    private static func update(
        in store: any KeyValueStore, _ block: (inout Profile) -> Void
    ) -> Bool {
        var ledger = ProfileBook.read(from: store)
        guard let active = ledger.active else { return false }
        let previous = ledger.activeProfile
        ledger.update(active, block)
        guard ledger.activeProfile != previous else { return false }
        ledger.write(in: store)
        return true
    }
}
