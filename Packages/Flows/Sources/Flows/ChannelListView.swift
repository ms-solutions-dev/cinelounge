import Core
import Diagnose
import Foundation
import PlaylistKit
import ProfileKit

/// Lays the profile as a window over a list catalog — **the same place
/// on both devices** (on-device test build 1332, 2026-09-27, findings 1 and 3; decision 25).
///
/// **The finding:** A channel list lies on the device; whose it is stands in the profile (AP41).
/// Filtering happened only in the settings overview; Live, catalog, channel favourites and
/// the "IPTV accesses" list read the whole device catalog. A freshly created profile thus saw
/// the access of the deleted one while the overview reported "nothing".
///
/// **Here and not in `PlaylistKit`**, because the package does not know the profile book; and not
/// per device, because two computations over the same question diverge.
public enum ChannelListView {

    /// Sets ``PlaylistKit/PlaylistStore/viewport`` to
    /// the active profile's ``ProfileKit/ProfileBook/channelListWindow(available:)``. The book
    /// is asked on every read (about 15 µs), not remembered at build: A profile switch
    /// changes it, and this catalog lives longer than a profile on the TV.
    ///
    /// - Returns: the same catalog, for passing on.
    @discardableResult
    ///
    /// **Before that, orphaned lists go to a profile** (phone, 2026-09-28) —
    /// ``ProfileKit/ProfileBook/adoptOrphaned(available:isFresh:)``.
    public static func set(
        _ storage: PlaylistStore, ledgerStore: any KeyValueStore = FileStore(),
        keychain: any KeyValueStore = SecureStore()
    ) -> PlaylistStore {
        rekey(storage, ledgerStore: ledgerStore)
        assignOrphans(storage, ledgerStore: ledgerStore, keychain: keychain)
        storage.viewport = { [unowned storage] in
            ProfileBook.read(from: ledgerStore).channelListWindow(
                available: storage.playlists.map(\.id))
        }
        return storage
    }

    /// Old random IDs onto the computed list key (``Core/ListKey``)
    /// — **on the phone too, including the references in the profile.**
    ///
    /// **The finding (iPad, 2026-09-29):** Continue Watching showed no IPTV titles and channels.
    /// The re-keying (``PlaylistKit/ListMigration``) ran only on the TV, on loading
    /// via `PlaylistStore.onDevice`; phone and iPad build their catalog directly. A list entered before
    /// AP42 kept its random number there, and every state from the
    /// other devices (`xtream|host|user#movie#…`) matched no list.
    ///
    /// - Returns: how many lists were re-keyed.
    @discardableResult
    public static func rekey(
        _ storage: PlaylistStore, ledgerStore: any KeyValueStore = FileStore()
    ) -> Int {
        let available = Set(storage.playlists.map(\.id))
        var migration: [String: String] = [:]
        for list in storage.playlists where list.id != list.key {
            guard !available.contains(list.key) else { continue }
            migration[list.id] = list.key
        }
        guard !migration.isEmpty else { return 0 }
        var ledger = ProfileBook.read(from: ledgerStore)
        let counted = ListMigration.perform(
            in: storage, ledger: ledgerStore, profile: ledger.profile.map(\.identifier.rawValue))
        for profile in ledger.profile {
            ledger.update(profile.identifier) { profile in
                for credential in profile.channelLists {
                    guard let legacy = credential.channelListID, let fresh = migration[legacy],
                        storage.playlists.contains(where: { $0.id == fresh })
                    else { continue }
                    profile.remove(credential)
                    profile.create(.channelList(identifier: fresh))
                }
            }
        }
        ledger.write(in: ledgerStore)
        Diagnose.hint(.login, "IPTV: \(counted) list(s) moved to the computed key")
        return counted
    }

    /// Gives lists without a profile to a profile — **also later, not only at build**
    /// (2026-09-28): If a profile comes from the cloud or is merged, a
    /// list can afterwards belong to none; it was there and yet invisible, and the
    /// IPTV films on the phone were missing. Plus a line with the numbers — without it no
    /// report showed whether lists are missing or merely hidden.
    ///
    /// - Returns: whether anything in the book changed.
    @discardableResult
    public static func assignOrphans(
        _ storage: PlaylistStore, ledgerStore: any KeyValueStore = FileStore(),
        keychain: any KeyValueStore = SecureStore()
    ) -> Bool {
        var ledger = ProfileBook.read(from: ledgerStore)
        let available = storage.playlists.map(\.id)
        let changed = ledger.adoptOrphaned(
            available: available,
            isFresh: { ProfileStore.isFresh($0.rawValue, in: keychain) })
        if changed {
            ledger.write(in: ledgerStore)
            Diagnose.hint(.login, "IPTV: lists without a profile assigned to the profile")
        }
        report(storage, ledger: ProfileBook.read(from: ledgerStore), keychain: keychain)
        return changed
    }

    /// Which lists the active profile sees and has switched on — the quantity by which
    /// it is decided whether the sources must be rebuilt.
    public static func window(
        _ storage: PlaylistStore, ledgerStore: any KeyValueStore = FileStore()
    ) -> Set<String> {
        let available = storage.playlists.map(\.id)
        let isVisible =
            ProfileBook.read(from: ledgerStore).channelListWindow(available: available) ?? Set(available)
        return Set(storage.playlists.filter { isVisible.contains($0.id) && $0.isEnabled }.map(\.id))
    }

    /// **Always recorded** (on-device test 2026-09-28): Until then these numbers were in the code as
    /// `step` and thus appeared in the report only with verbose recording — no
    /// report showed whether, on the iPhone, two profiles with the same name share the list or whether it
    /// is missing. Short IDs instead of names: The line should be verifiable without naming
    /// a person or a provider.
    static func report(
        _ storage: PlaylistStore, ledger: ProfileBook, keychain: any KeyValueStore
    ) {
        let profileName = ledger.profile.map { profile in
            short(profile.identifier.rawValue) + (profile.identifier == ledger.active ? "*" : "")
                + (ProfileStore.isFresh(profile.identifier.rawValue, in: keychain) ? " fresh" : "")
                + " \(profile.channelLists.count)L"
        }
        Diagnose.hint(.login, "Profiles: \(profileName.joined(separator: ", "))")
        let available = storage.playlists.map(\.id)
        let isVisible = ledger.channelListWindow(available: available) ?? Set(available)
        let listen = storage.playlists.map { list in
            let owner = ledger.profile.first {
                $0.channelLists.contains { $0.channelListID == list.id }
            }
            return short(list.id)
                + " of " + (owner.map { short($0.identifier.rawValue) } ?? "nobody")
                + (list.isEnabled ? "" : " off")
                + (storage.password(for: list.id)?.isEmpty == false ? "" : " without password")
                + (isVisible.contains(list.id) ? " visible" : "")
        }
        Diagnose.hint(
            .login,
            "IPTV: \(available.count) list(s) on the device, \(isVisible.count) in the active profile"
                + (listen.isEmpty ? "" : " — " + listen.joined(separator: "; ")))
    }

    /// The first eight characters of a UUID; a derived ID (`xtream|host|user`)
    /// carries provider and user and is named only as a checksum.
    static func short(_ identifier: String) -> String {
        if UUID(uuidString: identifier) != nil { return String(identifier.prefix(8)).lowercased() }
        let sum = identifier.unicodeScalars.reduce(UInt32(7)) { ($0 &* 31) &+ $1.value }
        return "abgeleitet-" + String(sum % 0xFFFF, radix: 16)
    }
}
