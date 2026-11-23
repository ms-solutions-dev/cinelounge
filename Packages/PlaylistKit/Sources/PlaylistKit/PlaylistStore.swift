import Combine
import Core
import Foundation

/// Manages the stored channel lists and the favorites.
///
/// Anyone with more than one list — their own, one from a friend, a purchased
/// account — wants to switch between them without losing any. That gives three
/// tasks that come together here:
///
/// 1. **The lists themselves**: create, rename, delete, switch on and off.
///    The order is not a side issue but the user's ranking: for duplicate
///    channels, the list that is higher up wins.
/// 2. **The credentials**: stored separately, see ``XtreamCredentials``.
/// 3. **The favorites**: apply across all lists, see ``favoriteKey(for:)``.
///
/// **Why bound to the main thread and not an `actor`:** The content is
/// settings state that the UI reads while drawing. As an `actor`, every access
/// from a view would be asynchronous, and every list would first be drawn empty
/// and then drawn again once filled. Merging the channels is the only
/// compute-heavy spot, and it costs only fractions of a millisecond even with a
/// thousand channels; the name normalization behind it is available as
/// `nonisolated` and can be used in the background.
@MainActor
public final class PlaylistStore: ObservableObject {

    // MARK: - Zustand

    /// The stored lists in the order the user has set.
    /// `@Published` so that settings and the Live area see the same thing: whoever
    /// adds a list should find its channels right away, without restarting the
    /// app.
    @Published public private(set) var playlists: [Playlist] = []

    /// The identifiers of the favorites — see ``favoriteKey(for:)``, not ``Channel/id``.
    /// Also `@Published`: a favorite set here must show up in the favorites row
    /// immediately, not only the next time the channels reload.
    @Published public private(set) var favorites: Set<String> = []

    /// The last error when reading or writing the store.
    ///
    /// Changes are always applied in memory, even if writing fails — otherwise the
    /// UI would show something other than what the user just set. So that the
    /// failure still does not vanish, it is kept here and can be reported in
    /// settings.
    public private(set) var lastFailure: Error?

    /// Store for the lists themselves: names, order, on/off state, favorites.
    private let store: KeyValueStore

    /// Store for the credentials. Deliberately a **second** one, see ``init(store:secrets:)``.
    private let secrets: KeyValueStore

    /// Store for the ``Core/StillLedger`` files — the favorites live there since AP42.
    private let ledger: KeyValueStore

    // MARK: - Store keys

    /// The number in the key is deliberate: if the storage format changes, it gets
    /// a new key instead of overwriting the old one into something unreadable.
    private static let playlistsKey = "playlists.v1"

    /// **Only read now, and only once.** Until AP42 the channel favorites lived
    /// here — as one list per device, belonging to everyone before. Since AP42
    /// they live in the person's ``Core/StillLedger``; ``StateTransfer`` brings the
    /// old data over on first launch. It is deleted one version later, so that a
    /// rollback stays possible (AP48).
    ///
    /// **`nonisolated`, because ``StateTransfer`` reads it during startup** — there
    /// is no main thread there, and a text literal does not need one.
    nonisolated static let favoritesKey = "playlists.favorites.v1"

    private static func credentialsKey(for playlistID: String) -> String {
        "playlist.credentials.\(playlistID)"
    }

    // MARK: - Aufbau

    /// Reads the existing catalog.
    ///
    /// **Why two stores:** List names, order and on/off state are harmless
    /// settings — they may live in the ordinary settings, end up in a backup and
    /// be printed when hunting a bug. Username and password of a purchased account
    /// may not: they belong in the Keychain. If both lay in the same container,
    /// the caller's carefulness would decide whether a password ends up in
    /// plain text in a backup. The separation takes that decision away from them —
    /// which is why the list store does not even contain the username, although
    /// ``Playlist/Kind/xtream(server:username:)`` carries it. It is taken out when
    /// saving and added back from ``secrets`` when loading.
    ///
    /// - Parameters:
    ///   - store: Store for the lists. For tests `InMemoryStore`.
    ///   - secrets: Store for the credentials. In production the Keychain.
    ///   - buch: Where the ``Core/StillLedger`` files live. In production ``FileStore``, for
    ///     tests `InMemoryStore`. **No default value**, for the same reason as in
    ///     ``onDevice(listen:credentials:oldLists:oldCredentials:ledger:profile:store:)``: a
    ///     default would have meant that every test that does not name it writes into
    ///     the real files on this machine — and then its outcome depends on what
    ///     another test left there beforehand.
    public init(store: KeyValueStore, secrets: KeyValueStore, ledger: KeyValueStore) {
        self.store = store
        self.secrets = secrets
        self.ledger = ledger

        loadLists()
        loadFavorites()
        ListGuard.notify(self)
    }

    /// Reads the lists from storage — **on construction and whenever someone calls.**
    ///
    /// **There are several of these stores, and that is the existing state** (AP43): `MainView`,
    /// `PlaylistAccounts` and the startup each hold one, all over the **same** store.
    /// When one writes, the others notice nothing — they read on construction
    /// and never again. For a screen that disappears shortly anyway, that has no
    /// consequences; for a channel list that the sync brings in from iCloud, it
    /// was the line "appears only on the next launch".
    ///
    /// **The trigger and not one store for everything.** Turning this into a single
    /// catalog would mean rebuilding three construction paths, two of which hang off the
    /// launch screen — for a case that is fixed by re-reading. Same design as
    /// ``loadFavorites()``, and for the same reason.
    ///
    /// **An empty store is the normal case on first launch and not an error.**
    /// `try?` therefore swallows the "not found"; only damaged content is
    /// reported.
    public func loadLists() {
        guard let json = try? store.value(for: Self.playlistsKey),
            let data = json.data(using: .utf8)
        else { return }
        do {
            let stored = try JSONDecoder().decode([StoredPlaylist].self, from: data)
            playlists = stored.map { $0.playlist(username: username(for: $0.id)) }
        } catch {
            Diagnostics.defect(
                "Channel lists not read: \(Diagnostics.explain(error))", since: nil, area: "Ablage")
            lastFailure = error
        }
    }

    /// Reads the favorites from the Standbuch of the person currently watching.
    ///
    /// **Also to be called after every profile switch.** This catalog lives as long as the
    /// app; without re-reading, the favorites row would keep showing the previous
    /// viewer's favorites after the switch — and the next tap on a star would write them into
    /// the new viewer's book.
    public func loadFavorites() {
        favorites = Set(StillLedger.read(from: ledger, forItem: ProfilePointer.active).state.channelFavorites)
    }

    // MARK: - Listen verwalten

    /// Which lists the person currently watching maintains — `nil` means: all.
    ///
    /// **The finding from the on-device test (build 1332, 2026-09-27):** A freshly created profile
    /// saw the deleted profile's account under "IPTV accounts", and Live, catalog and favorites
    /// kept playing it — while the settings overview, which counts per profile,
    /// said "nothing". A list lives on the device (with its password in the Keychain), **whose**
    /// it is is stored in the profile (AP41); until now, filtering happened in only one place.
    ///
    /// **A handle and not a value**, because this catalog lives longer than a profile switch
    /// (on the TV, `MainView` holds it); the question is asked at the moment of reading.
    ///
    /// **Here and not at every reader:** Live, catalog and channel search all ask
    /// ``enabledPlaylists``; whoever attaches the filter at each place separately forgets
    /// the fifth. The package does not know the profile book — whoever knows it sets the handle.
    public var viewport: (@MainActor () -> Set<String>?)?

    /// The lists seen by the person currently watching — in their ranking, including the
    /// switched-off ones (for settings). All of them without ``viewport``.
    public var visiblePlaylists: [Playlist] {
        guard let window = viewport?() else { return playlists }
        return playlists.filter { window.contains($0.id) }
    }

    /// The switched-on lists in their ranking — **through the ``viewport``.**
    public var enabledPlaylists: [Playlist] {
        visiblePlaylists.filter(\.isEnabled)
    }

    public func playlist(withID id: String) -> Playlist? {
        playlists.first { $0.id == id }
    }

    /// Appends a list at the end.
    ///
    /// An already existing identifier is replaced in place instead of appended a
    /// second time: two entries with the same identifier would produce a list in
    /// which renaming and deleting each hit only one of the two.
    public func add(_ playlist: Playlist, password: String? = nil) {
        if let index = playlists.firstIndex(where: { $0.id == playlist.id }) {
            playlists[index] = playlist
        } else {
            playlists.append(playlist)
        }

        if let username = playlist.kind.username {
            writeCredentials(
                XtreamCredentials(
                    username: username, password: password ?? self.password(for: playlist.id) ?? ""),
                for: playlist.id
            )
        }

        persistPlaylists()
    }

    /// Renames a list. The identifier stays — the credentials hang off it.
    public func rename(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = playlists.firstIndex(where: { $0.id == id }) else {
            return
        }

        playlists[index].name = trimmed
        persistPlaylists()
    }

    /// Changes address, account and guide source of a list — **without recreating it.**
    ///
    /// **The finding of 2026-09-07:** Until then this store could rename, switch on and
    /// off, move and delete — but not **change**. Anyone whose provider password
    /// expired was left with deleting and recreating; that drops the
    /// identifier, and with it group order, hidden groups and
    /// channel marks, which all hang off it. Among competitors this is exactly the
    /// most common complaint — "remove and recreate" is the standard advice there.
    ///
    /// **The identifier stays, and that is the whole purpose.** It is the key under
    /// which credentials, preferences and marks live; whoever reassigns it loses everything
    /// attached to it, without anyone having talked about deleting.
    ///
    /// - Parameter kennwort: `nil` leaves the stored one in place — for the case that
    ///   someone only corrects the address. An empty text explicitly deletes it.
    public func update(
        _ id: String, name: String? = nil, kind: Playlist.Kind? = nil,
        epgURL: URL?? = nil, password secret: String? = nil
    ) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }

        if let name {
            let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { playlists[index].name = clean }
        }
        if let kind { playlists[index].kind = kind }
        // **Wrapped twice, so that "delete" can be told apart from "do not touch".**
        // A plain `URL?` could mean both, and the guide source would silently be gone
        // with every address correction.
        if let epgURL { playlists[index].epgURL = epgURL }

        if let secret, case .xtream(_, let username) = playlists[index].kind {
            setCredentials(
                secret.isEmpty
                    ? nil : XtreamCredentials(username: username, password: secret),
                for: id)
        } else if let kind, case .xtream(_, let username) = kind, let oldPassword = password(for: id) {
            // **The username may have changed, the password not.** The
            // credentials carry the user along; without this follow-up the Keychain would
            // still hold the old one, and the next fetch would log in with it.
            setCredentials(XtreamCredentials(username: username, password: oldPassword), for: id)
        }

        persistPlaylists()
    }

    /// Deletes a list **together with** its credentials.
    ///
    /// Deleting the credentials too is not tidying on the side: if the
    /// password stayed in the Keychain, it would outlive the entry that made it
    /// visible, and could never be removed through the UI
    /// again.
    public func remove(_ id: String) {
        guard playlists.contains(where: { $0.id == id }) else { return }

        playlists.removeAll { $0.id == id }
        try? secrets.remove(Self.credentialsKey(for: id))
        persistPlaylists()
    }

    /// Gives a list a new key — **together with everything attached to it.**
    ///
    /// Needed in two places, and both are the same operation from two directions:
    /// for the old data, whose identifier is a random number (``ListMigration``), and for the
    /// provider move, where the address changes and the computed key with
    /// it. What moves here is the entry and its account; ``ListMigration`` moves
    /// the state, because that lives in another store.
    ///
    /// **An already taken new key leaves everything as it is.** It would mean that the same list
    /// is registered twice; merging the two would be a decision
    /// about which name and which order wins, and nobody makes that here.
    ///
    /// - Returns: Whether the key was changed.
    @discardableResult
    public func rekey(_ old: String, after fresh: String) -> Bool {
        guard old != fresh, !fresh.isEmpty,
            let index = playlists.firstIndex(where: { $0.id == old }),
            !playlists.contains(where: { $0.id == fresh })
        else { return false }

        let credential = credentials(for: old)
        let previous = playlists[index]
        playlists[index] = Playlist(
            id: fresh, name: previous.name, kind: previous.kind,
            isEnabled: previous.isEnabled, epgURL: previous.epgURL)

        if let credential {
            writeCredentials(credential, for: fresh)
            try? secrets.remove(Self.credentialsKey(for: old))
        }

        persistPlaylists()
        return true
    }

    public func setEnabled(_ isEnabled: Bool, for id: String) {
        guard let index = playlists.firstIndex(where: { $0.id == id }),
            playlists[index].isEnabled != isEnabled
        else { return }

        playlists[index].isEnabled = isEnabled
        persistPlaylists()
    }

    /// Moves a list to the given position.
    ///
    /// The position is clamped to the valid range instead of rejected: the
    /// caller is a UI where one keeps pressing at the end of the list,
    /// and there "stays at the bottom" is the expected answer, not an error.
    public func move(_ id: String, to index: Int) {
        guard let current = playlists.firstIndex(where: { $0.id == id }) else { return }

        let target = min(max(index, 0), playlists.count - 1)
        guard target != current else { return }

        let entry = playlists.remove(at: current)
        playlists.insert(entry, at: target)
        persistPlaylists()
    }

    // MARK: - Zugangsdaten

    public func credentials(for playlistID: String) -> XtreamCredentials? {
        guard let json = try? secrets.value(for: Self.credentialsKey(for: playlistID)),
            let data = json.data(using: .utf8)
        else { return nil }

        return try? JSONDecoder().decode(XtreamCredentials.self, from: data)
    }

    public func password(for playlistID: String) -> String? {
        credentials(for: playlistID)?.password
    }

    /// Sets or deletes the credentials of a list.
    ///
    /// The username is also contained in ``Playlist/Kind/xtream(server:username:)``.
    /// It is carried along here so that the UI can display it without asking the
    /// Keychain — but the truth lives in the credentials store,
    /// and only from there is it read when loading.
    public func setCredentials(_ credentials: XtreamCredentials?, for playlistID: String) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }

        if let credentials {
            writeCredentials(credentials, for: playlistID)
            if case .xtream(let server, _) = playlists[index].kind {
                playlists[index].kind = .xtream(server: server, username: credentials.username)
            }
        } else {
            try? secrets.remove(Self.credentialsKey(for: playlistID))
            if case .xtream(let server, _) = playlists[index].kind {
                playlists[index].kind = .xtream(server: server, username: "")
            }
        }

        persistPlaylists()
    }

    private func writeCredentials(_ credentials: XtreamCredentials, for playlistID: String) {
        do {
            let data = try JSONEncoder().encode(credentials)
            guard let json = String(data: data, encoding: .utf8) else { return }
            try secrets.set(json, for: Self.credentialsKey(for: playlistID))
        } catch {
            Diagnostics.defect(
                "Credentials not stored: \(Diagnostics.explain(error))", since: nil, area: "Ablage")
            lastFailure = error
        }
    }

    private func username(for playlistID: String) -> String {
        credentials(for: playlistID)?.username ?? ""
    }

    // MARK: - Favoriten

    /// The identifier under which a channel is remembered as a favorite.
    ///
    /// **Why not ``Channel/id``:** It contains the running number from the
    /// file. If the provider inserts a channel tomorrow, all channels behind it shift,
    /// and every favorite would point at the wrong channel — the
    /// worst case, because it goes unnoticed.
    ///
    /// **Why not the address:** For an Xtream account the username is part of
    /// the address. After every renewal it is a different one.
    ///
    /// **Why not `tvg-id`:** It is stable, but not present everywhere, and
    /// two providers assign different ones for the same channel. That would break
    /// exactly what matters here: favorites should apply **across lists**,
    /// so that they do not disappear when you switch providers.
    ///
    /// What remains is the name, brought to a comparison form: without upper and
    /// lower case, without umlaut characters and without punctuation — "Das Nordlicht HD",
    /// "das-nordlicht hd" and "DAS NORDLICHT | HD" yield the same identifier.
    ///
    /// **The quality suffix is part of it again since 2026-08-15** Before that
    /// it was cut off, and "KopruHaber HD" marked UHD, FHD and HEVC too —
    /// but the viewer deliberately picks exactly one version (on-device finding
    /// 2026-08-15). Existing favorites from the old scheme match no
    /// new identifier and are cleaned up on the next sync; they have to be
    /// set once again.
    public nonisolated static func favoriteKey(for channel: Channel) -> String {
        favoriteKey(forName: channel.favoriteName)
    }

    public nonisolated static func favoriteKey(forName name: String) -> String {
        let folded = name.folding(
            options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
            locale: nil
        )

        // Turn punctuation into separators. That way "Sola Sport | HD" and
        // "Sola-Sport HD" coincide without needing a rule for every spelling.
        let separated = String(
            folded.unicodeScalars.map { scalar in
                CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
            }
        )

        // **The quality suffix stays part of the identifier** (on-device finding 2026-08-15,
        // reverted): Until then "HD", "UHD", "FHD", "HEVC" and
        // resolutions were cut off at the end, so that a favorite survives a
        // provider switch with a different spelling. The price was
        // higher than expected — whoever marked "KopruHaber HD" got UHD, FHD and
        // HEVC as well, since for the identifier these were all the same
        // channel. What is wanted is the one entry you actually
        // picked: the variants of the same channel are deliberately different
        // things to the viewer (different bandwidth, different engine path).
        // Spelling, umlauts and punctuation are still normalized;
        // only true name equality still shares a favorite.
        let tokens = separated.split(separator: " ").map(String.init)

        return tokens.joined(separator: " ")
    }

    public func isFavorite(_ channel: Channel) -> Bool {
        favorites.contains(Self.favoriteKey(for: channel))
    }

    public func setFavorite(_ isFavorite: Bool, for channel: Channel) {
        let key = Self.favoriteKey(for: channel)
        guard !key.isEmpty else { return }

        let changed = isFavorite ? favorites.insert(key).inserted : favorites.remove(key) != nil
        guard changed else { return }

        record([.senderfavorit(key: key, isFavorite)])
    }

    public func toggleFavorite(_ channel: Channel) {
        setFavorite(!isFavorite(channel), for: channel)
    }

    /// Drops favorites for which there is no channel anymore.
    ///
    /// **Call only after a complete, successful reload of all switched-on
    /// lists.** Otherwise a provider that is currently unreachable
    /// silently clears out the favorites of its channels — a loss the
    /// user notices only when it is too late. For the same reason the
    /// function does nothing for an empty channel list: that is almost always a
    /// failed fetch and not a provider without channels.
    public func pruneFavorites(against channels: [Channel]) {
        guard !channels.isEmpty else { return }

        let alive = Set(channels.map(Self.favoriteKey(for:)))
        let kept = favorites.intersection(alive)
        guard kept != favorites else { return }

        let dropped = favorites.subtracting(kept)
        favorites = kept
        record(dropped.sorted().map { .senderfavorit(key: $0, false) })
    }

    // MARK: - Merging

    /// Merges the channels of the switched-on lists into one list.
    ///
    /// - Parameter loaded: The channels read, per list identifier. A list that is not
    ///   in it is skipped — a list whose fetch failed therefore disappears from the
    ///   display instead of being shown empty.
    ///
    /// Three rules, in this order:
    ///
    /// 1. **Order**: The lists in the user's ranking, within
    ///    a list the order of the file. Re-sorting by name would be wrong
    ///    here — with many providers the order of the file is the channel
    ///    numbering the user knows from cable TV.
    /// 2. **Duplicates across lists** drop out; the list that is higher up
    ///    wins. That is the point of the ranking.
    /// 3. **Duplicates within a list** stay, provided they have different
    ///    addresses. "Das Nordlicht (1080p)" and "Das Nordlicht (576p)" are the same channel as far as the
    ///    identifier goes, but the user wants the choice when one
    ///    resolution stutters. Only the truly identical entry — same name,
    ///    same address — drops out.
    public func merged(_ loaded: [String: [Channel]]) -> [Channel] {
        var result: [Channel] = []
        var claimedBy: [String: String] = [:]
        var seenInList = Set<String>()

        for playlist in enabledPlaylists {
            guard let channels = loaded[playlist.id] else { continue }

            for channel in channels {
                let exact = [
                    playlist.id, channel.cleanName.lowercased(), channel.streamURL.absoluteString,
                ].joined(separator: "|")
                guard seenInList.insert(exact).inserted else { continue }

                let key = Self.favoriteKey(for: channel)
                if let owner = claimedBy[key], owner != playlist.id { continue }
                claimedBy[key] = playlist.id

                var enriched = channel
                enriched.isFavorite = favorites.contains(key)
                result.append(enriched)
            }
        }

        return result
    }

    // MARK: - Zwei Ablagen werden eine

    /// The identifier under which two entries mean the **same** list: address and
    /// user.
    ///
    /// **Not ``Playlist/id``.** The same list, entered in two places, carries
    /// two identifiers — that is exactly the case ``adopt(from:)`` has to tell
    /// apart. The name deliberately does not count: whoever renamed their list on the TV
    /// does not therefore have it twice.
    static func origin(of playlist: Playlist) -> String {
        switch playlist.kind {
        case .m3u(let url): "m3u|\(url.absoluteString)"
        case .xtream(let server, let username): "xtream|\(server.absoluteString)|\(username)"
        case .jellyfinLiveTV: "jellyfin"
        }
    }

    /// Brings over what is in a second store — and overwrites nothing.
    ///
    /// **What for** (AP39, 2026-09-20): Until then, first-time setup and takeover
    /// from the phone wrote into the Keychain's default service, while the Live area
    /// read from one of its own. Whoever entered a list never saw it again. The stores
    /// have been one since (``onDevice(listen:credentials:oldLists:oldCredentials:store:)``),
    /// and what lies in the old service on already set-up devices comes over here once.
    ///
    /// **The local catalog wins.** It is the visible one — what the viewer has in front of
    /// them in settings must not change through a cleanup.
    /// From the second store comes only what does not yet exist here according to ``origin(of:)``,
    /// including the password. Favorites apply across all lists and are
    /// united instead of replaced.
    ///
    /// - Returns: How many lists were added — for the test and for the log.
    @discardableResult
    public func adopt(from other: PlaylistStore) -> Int {
        var available = Set(playlists.map(Self.origin(of:)))
        var added = 0

        for list in other.playlists where available.insert(Self.origin(of: list)).inserted {
            add(list, password: other.password(for: list.id))
            added += 1
        }

        let newlyAdded = other.favorites.subtracting(favorites)
        if !newlyAdded.isEmpty {
            favorites.formUnion(newlyAdded)
            record(newlyAdded.sorted().map { .senderfavorit(key: $0, true) })
        }

        return added
    }

    // MARK: - Schreiben

    private func persistPlaylists() {
        do {
            let data = try JSONEncoder().encode(playlists.map(StoredPlaylist.init))
            guard let json = String(data: data, encoding: .utf8) else { return }
            try store.set(json, for: Self.playlistsKey)
        } catch {
            Diagnostics.defect(
                "Channel lists not stored: \(Diagnostics.explain(error))", since: nil, area: "Ablage")
            lastFailure = error
        }
    }

    /// Writes the favorites into the Standbuch.
    ///
    /// **One event per mark and not the whole list.** During the sync (AP43) it must
    /// be recognizable *what* the viewer did: from two lists one could not
    /// tell whether one was added here or one dropped there — and one of
    /// the two readings takes someone's favorite away.
    private func record(_ events: [StillEvent]) {
        guard !events.isEmpty else { return }
        var state = StillLedger.read(from: ledger, forItem: ProfilePointer.active)
        for event in events { state.record(event) }
        state.write(in: ledger, forItem: ProfilePointer.active)
    }
}

// MARK: - Zugangsdaten

/// Username and password of an Xtream account.
///
/// Separate from ``Playlist``, because the two are stored separately — see
/// ``PlaylistStore/init(store:secrets:)``.
public struct XtreamCredentials: Sendable, Equatable, Codable {
    public let username: String
    public let password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

// MARK: - Ablageform

/// The form in which a list is stored.
///
/// A struct of its own and not ``Playlist`` itself: first, ``Playlist``
/// in the `Core` module deliberately has no Codable, so that the storage format does not
/// move along unnoticed as soon as a field is added there. Second — and that
/// is what matters here — the username is missing on purpose.
private struct StoredPlaylist: Codable {

    enum Kind: Codable {
        case m3u(url: URL)
        /// Without username: that lives in the credentials store.
        case xtream(server: URL)
        case jellyfinLiveTV
    }

    let id: String
    var name: String
    var kind: Kind
    var isEnabled: Bool
    var epgURL: URL?

    init(_ playlist: Playlist) {
        self.id = playlist.id
        self.name = playlist.name
        self.isEnabled = playlist.isEnabled
        self.epgURL = playlist.epgURL

        switch playlist.kind {
        case .m3u(let url): self.kind = .m3u(url: url)
        case .xtream(let server, _): self.kind = .xtream(server: server)
        case .jellyfinLiveTV: self.kind = .jellyfinLiveTV
        }
    }

    /// Rebuilds the list and inserts the username from the second store.
    func playlist(username: String) -> Playlist {
        let kind: Playlist.Kind =
            switch self.kind {
            case .m3u(let url): .m3u(url)
            case .xtream(let server): .xtream(server: server, username: username)
            case .jellyfinLiveTV: .jellyfinLiveTV
            }

        return Playlist(id: id, name: name, kind: kind, isEnabled: isEnabled, epgURL: epgURL)
    }
}

extension Playlist.Kind {

    /// The username, if the kind of list has one.
    fileprivate var username: String? {
        if case .xtream(_, let username) = self { return username }
        return nil
    }
}
