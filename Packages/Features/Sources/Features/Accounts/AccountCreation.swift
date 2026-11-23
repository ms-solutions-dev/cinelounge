import Core
import Foundation
import ParentalControls

/// The narrow door for the app layer: **classify a new sign-in.**
///
/// **Why this type exists.** The question about the account kind arises where a
/// sign-in arrives — and that is `RootView` in the app layer. The answer lands in
/// ``ChildAccountList``, the question "is a PIN set at all" is answered by ``Pin``;
/// both live in the parental-controls package. So that the app does not have to know
/// the whole package for this **one** question, here is a door with two handles and nothing else.
///
/// **Two functions and no holder.** There is nothing to remember: Both handles read and
/// write directly to the store, and they happen exactly once per sign-in.
public nonisolated enum AccountCreation {

    /// Whether a PIN is stored.
    ///
    /// The information is needed to **tell** the user: Without a PIN the
    /// child-account marker is information and not a lock — ``ProtectionRule/applies``
    /// requires both. Concealing that would mean leaving someone in the belief that they
    /// have protected their child.
    public static func isPinSet(store: any KeyValueStore = SecureStore()) -> Bool {
        Pin(store: store).isSet
    }

    /// Records the account kind for a freshly added access.
    ///
    /// **Exactly once, on creation.** An account that could be switched afterwards
    /// could also be switched back — and whoever knows the PIN would then not have to bypass the
    /// parental controls, they would switch them off.
    public static func mark(
        kind: Bool, forItem credential: ServerCredentials,
        list: ChildAccountList = ChildAccountList()
    ) {
        list.set(kind: kind, forItem: Account.Identifier(credential).stored)
    }
}
