import Foundation

/// Whoever wants to see a channel list as soon as it is there (AP43).
///
/// **The app keeps several ``PlaylistStore`` instances, and that is no oversight.**
/// `MainView`, `PlaylistAccounts` and the startup each build one; they are different
/// views of **one** store. As long as only the UI writes, this goes
/// unnoticed — whoever writes also redraws.
///
/// **The sync from iCloud writes from the outside, though.** A list that comes from another
/// device lands immediately in the Keychain and in none of the instances; it became visible
/// only at the next start. For a list from afar that would still be tolerable — for
/// ongoing operation it would not, and the boundary between the two is not one that a
/// screen can draw.
///
/// **Weak and unordered.** This guard keeps nobody alive and tells
/// nobody when it is their turn: It only knows who is present and asks them
/// to re-read. An instance that has gone in the meantime drops out at the next call.
@MainActor
public enum ListGuard {

    private struct Pointer {
        weak var storage: PlaylistStore?
    }

    private static var catalogs: [Pointer] = []

    /// A fresh instance registers — ``PlaylistStore/init(store:secrets:ledger:)`` does
    /// this itself. **Calling it by hand would be the one place that forgets.**
    static func notify(_ storage: PlaylistStore) {
        catalogs.removeAll { $0.storage == nil }
        catalogs.append(Pointer(storage: storage))
    }

    /// Something has changed in the lists — all of them re-read.
    public static func call() {
        catalogs.removeAll { $0.storage == nil }
        for pointer in catalogs {
            pointer.storage?.loadLists()
        }
    }

    /// How many instances are currently kept — for the checks.
    static var count: Int {
        catalogs.removeAll { $0.storage == nil }
        return catalogs.count
    }
}
