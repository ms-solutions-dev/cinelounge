import Core
import Foundation

extension PlaylistStore {

    /// The service in which the lists themselves live: names, order, switch state,
    /// favorites.
    ///
    /// **A literal and not ``AppBundleIdentifiers/bundles``**, although both give the same
    /// text on the device: What stands here is not a name but the address of a
    /// catalog that has been on set-up devices since 2026-07-28. A derived
    /// identifier would point somewhere else in the TopShelf extension and under `swift test`
    /// and would lose it.
    private static let listService = "dev.ms-solutions.cinelounge.playlists"

    /// The service for the credentials — the separation is the point, see
    /// ``PlaylistStore/init(store:secrets:)``.
    private static let credentialsService = "dev.ms-solutions.cinelounge.playlistSecrets"

    /// The marker that the old default service has been read out once.
    ///
    /// **In the ordinary settings and not in the Keychain:** It is not
    /// access information, and anyone who sets the app up again should get the catalog back from a
    /// restored backup — its absence then costs only
    /// two reads that find nothing.
    private static let mergedKey = "playlists.ablage.vereint.v1"

    /// The channel lists of this device — **the only place where the service names
    /// appear.**
    ///
    /// **The finding** (AP39, profile review of 2026-09-19): There were three places that
    /// opened a store, and two of them took the default service —
    /// `CineLoungeApp` at first setup and ``Takeover`` for the bundle from the
    /// phone. `MainView` read from the named one. What was entered
    /// therefore never appeared in the Live area; since `acb9e62` (2026-07-28), so almost two months.
    ///
    /// **Why the named service wins and not the default:** That is where what the
    /// viewer sees and maintains in the settings lives — this catalog does not move.
    /// And it keeps lists and credentials apart in two services; the default service
    /// put both into the same one.
    ///
    /// **What is in the old service stays there.** It is brought
    /// over once (``adopt(from:)``) and not deleted: Deleting would be the
    /// only step here that makes something irrecoverable, and it would gain nothing
    /// except a tidier Keychain. The marker ensures that deleted lists
    /// do not reappear at the next start.
    ///
    /// **The stores exist only for checks; `nil` means this device's Keychain.**
    /// They are not default values in the signature, because a
    /// default value would have to make the service names public — and then they would
    /// again stand in more than one place.
    public static func onDevice(
        listen: KeyValueStore? = nil,
        credentials: KeyValueStore? = nil,
        oldLists: KeyValueStore? = nil,
        oldCredentials: KeyValueStore? = nil,
        ledger: KeyValueStore? = nil,
        legacyState: KeyValueStore? = nil,
        profile: [String] = [],
        store: UserDefaults = .standard
    ) -> PlaylistStore {
        let ledgerStore = ledger ?? FileStore()
        let catalog = PlaylistStore(
            store: listen ?? SecureStore(service: listService),
            secrets: credentials ?? SecureStore(service: credentialsService),
            ledger: ledgerStore
        )

        if !store.bool(forKey: mergedKey) {
            catalog.adopt(
                from: PlaylistStore(
                    store: oldLists ?? SecureStore(), secrets: oldCredentials ?? SecureStore(),
                    ledger: ledgerStore))
            store.set(true, forKey: mergedKey)
        }

        // **The old state goes into the book before re-keying** (AP42, 2026-09-21).
        //
        // The order is the whole difficulty at this point: The legacy catalog
        // (`vod.memory.v1`, `live.lastChannel*`, `playlists.favorites.v1`) carries the old
        // random IDs. If re-keying ran first, it would afterwards sit under
        // IDs that no list carries any more — and nobody could ever get past that, because
        // re-keying then finds nothing left to move.
        StateTransfer.fromDevice(
            listen: catalog.playlists.map(\.id),
            from: legacyState ?? SecureStore(),
            in: ledgerStore)

        // **After the takeover and without a marker.** What comes from the old service carries
        // random numbers as well; and a provider can move at any time, not just
        // once. Where there is nothing to re-key, the pass costs one comparison per
        // list — see ``ListMigration``.
        //
        // **Every book, not just that of the person currently watching** — a
        // list key belongs to the device. Whoever does not pass the profiles re-keys only
        // the device base; that is the state before first setup and, for devices
        // without profiles, the whole truth.
        ListMigration.perform(
            in: catalog, ledger: ledgerStore, profile: profile)

        // **Finally re-read the favorites.** At setup the book was still empty; only
        // the takeover put them in and the re-keying straightened them out.
        catalog.loadFavorites()

        return catalog
    }
}
