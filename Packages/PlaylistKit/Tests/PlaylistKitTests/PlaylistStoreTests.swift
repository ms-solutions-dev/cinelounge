import Core
import Foundation
import Testing

@testable import PlaylistKit

/// Tested is what goes wrong when handling several lists.
///
/// Two things are in the foreground, because their loss goes unnoticed and
/// cannot be undone: the ranking of the lists set by the user
/// and the favourites. Both must survive a reload in which the provider
/// has inserted, renamed or reordered channels.
@Suite("Managing channel lists")
@MainActor
struct PlaylistStoreTests {

    // MARK: - Hilfen

    /// A pair of stores as in production: lists here, credentials there.
    private func makeStore() -> (PlaylistStore, InMemoryStore, InMemoryStore) {
        let settings = InMemoryStore()
        let secrets = InMemoryStore()
        return (PlaylistStore(store: settings, secrets: secrets, ledger: InMemoryStore()), settings, secrets)
    }

    private func m3u(_ id: String, _ name: String, enabled: Bool = true) -> Playlist {
        Playlist(
            id: id,
            name: name,
            kind: .m3u(URL(string: "http://server/\(id).m3u")!),
            isEnabled: enabled
        )
    }

    /// A channel with an ID in the layout of the M3U parser — that is, **with**
    /// the running number, so that the checks see the same unstable ID as
    /// the app.
    private func channel(
        _ name: String,
        list: String,
        ordinal: Int,
        url: String? = nil
    ) -> Channel {
        Channel(
            id: "\(list)#\(name)#\(ordinal)",
            name: name,
            streamURL: URL(string: url ?? "http://\(list)/\(ordinal)")!,
            playlistID: list
        )
    }

    // MARK: - Der leere Anfang

    @Test("An empty storage yields an empty, valid management")
    func emptyStore() {
        // The first launch of the app. A bug here would be the worst: the app
        // would never reach the screen where you create the first list.
        let (store, _, _) = makeStore()

        #expect(store.playlists.isEmpty)
        #expect(store.favorites.isEmpty)
        #expect(store.lastFailure == nil)
        #expect(store.merged([:]).isEmpty)
    }

    @Test("Damaged content is reported instead of stopping the app")
    func brokenContent() throws {
        let settings = InMemoryStore()
        try settings.set("kein JSON", for: "playlists.v1")

        let store = PlaylistStore(store: settings, secrets: InMemoryStore(), ledger: InMemoryStore())

        #expect(store.playlists.isEmpty)
        #expect(store.lastFailure != nil, "the failure must not vanish without a trace")
    }

    // MARK: - Listen verwalten

    @Test("An added list appears in the management")
    func addPlaylist() {
        let (store, _, _) = makeStore()

        store.add(m3u("a", "Meine Liste"))

        #expect(store.playlists.map(\.name) == ["Meine Liste"])
    }

    @Test("Renaming changes the name, not the identifier")
    func rename() {
        // The credentials hang on the ID. If renaming issued a new one,
        // user name and password could no longer be found afterwards.
        let (store, _, _) = makeStore()
        store.add(m3u("a", "Alter Name"))

        store.rename("a", to: "Neuer Name")

        #expect(store.playlists.first?.id == "a")
        #expect(store.playlists.first?.name == "Neuer Name")
    }

    @Test("An empty name is rejected")
    func emptyNameRejected() {
        // A nameless row in Settings can no longer be attributed.
        let (store, _, _) = makeStore()
        store.add(m3u("a", "Meine Liste"))

        store.rename("a", to: "   ")

        #expect(store.playlists.first?.name == "Meine Liste")
    }

    @Test("A deleted list disappears")
    func remove() {
        let (store, _, _) = makeStore()
        store.add(m3u("a", "A"))
        store.add(m3u("b", "B"))

        store.remove("a")

        #expect(store.playlists.map(\.id) == ["b"])
    }

    @Test("An unknown identifier changes nothing")
    func unknownIdentifier() {
        let (store, _, _) = makeStore()
        store.add(m3u("a", "A"))

        store.rename("gibt-es-nicht", to: "X")
        store.remove("gibt-es-nicht")
        store.setEnabled(false, for: "gibt-es-nicht")
        store.move("gibt-es-nicht", to: 0)

        #expect(store.playlists.map(\.name) == ["A"])
        #expect(store.playlists.first?.isEnabled == true)
    }

    @Test("The same identifier a second time replaces the entry in place")
    func addTwice() {
        // Otherwise the list would be there twice, and deleting would hit only one half.
        let (store, _, _) = makeStore()
        store.add(m3u("a", "A"))
        store.add(m3u("b", "B"))

        store.add(m3u("a", "A neu"))

        #expect(store.playlists.map(\.id) == ["a", "b"])
        #expect(store.playlists.first?.name == "A neu")
    }

    // MARK: - Reihenfolge

    @Test("The order of the lists stays as it was created")
    func insertionOrder() {
        let (store, _, _) = makeStore()

        for id in ["a", "b", "c", "d"] {
            store.add(m3u(id, id.uppercased()))
        }

        #expect(store.playlists.map(\.id) == ["a", "b", "c", "d"])
    }

    @Test("Moving puts the list at the desired position")
    func move() {
        let (store, _, _) = makeStore()
        for id in ["a", "b", "c"] { store.add(m3u(id, id)) }

        store.move("c", to: 0)

        #expect(store.playlists.map(\.id) == ["c", "a", "b"])
    }

    @Test("Moving past the end lands at the end instead of failing")
    func moveBeyondEnd() {
        // In the UI you keep pressing at the edge. A crash or an
        // error message would be the wrong answer there.
        let (store, _, _) = makeStore()
        for id in ["a", "b", "c"] { store.add(m3u(id, id)) }

        store.move("a", to: 99)
        store.move("b", to: -5)

        #expect(store.playlists.map(\.id) == ["b", "c", "a"])
    }

    // MARK: - Saving and loading

    @Test("Lists, order and switch state survive saving and loading")
    func roundTrip() {
        let settings = InMemoryStore()
        let secrets = InMemoryStore()

        let first = PlaylistStore(store: settings, secrets: secrets, ledger: InMemoryStore())
        first.add(m3u("a", "A"))
        first.add(m3u("b", "B"))
        first.add(
            Playlist(id: "c", name: "C", kind: .jellyfinLiveTV, epgURL: URL(string: "http://e/x")!))
        first.move("c", to: 0)
        first.setEnabled(false, for: "b")

        let second = PlaylistStore(store: settings, secrets: secrets, ledger: InMemoryStore())

        #expect(second.playlists.map(\.id) == ["c", "a", "b"])
        #expect(second.playlists.map(\.name) == ["C", "A", "B"])
        #expect(second.playlists.map(\.isEnabled) == [true, true, false])
        #expect(second.playlists.first?.epgURL?.absoluteString == "http://e/x")
        #expect(second.playlists.first?.kind == .jellyfinLiveTV)
        #expect(second.lastFailure == nil)
    }

    @Test("The address of an M3U list survives saving and loading")
    func kindRoundTrip() {
        let settings = InMemoryStore()
        let secrets = InMemoryStore()

        PlaylistStore(store: settings, secrets: secrets, ledger: InMemoryStore()).add(m3u("a", "A"))
        let reloaded = PlaylistStore(store: settings, secrets: secrets, ledger: InMemoryStore())

        #expect(reloaded.playlists.first?.kind == .m3u(URL(string: "http://server/a.m3u")!))
    }

    // MARK: - Zugangsdaten getrennt ablegen

    @Test("Password and user name are not in the store of the list names")
    func credentialsAreNotInSettings() throws {
        // The actual reason for the second store: the list store may travel into
        // a backup without a purchased account going along.
        let (store, settings, secrets) = makeStore()

        store.add(
            Playlist(
                id: "x",
                name: "Gekaufter Zugang",
                kind: .xtream(server: URL(string: "http://anbieter:8080")!, username: "kunde42")
            ),
            password: "geheim"
        )

        let written = try settings.value(for: "playlists.v1")

        #expect(!written.contains("geheim"))
        #expect(!written.contains("kunde42"))
        #expect(written.contains("anbieter"), "the server address itself belongs to the list")
        #expect(try secrets.value(for: "playlist.credentials.x").contains("geheim"))
    }

    @Test("The user name of an Xtream list is back after loading")
    func usernameRestored() {
        let settings = InMemoryStore()
        let secrets = InMemoryStore()
        let server = URL(string: "http://anbieter:8080")!

        let first = PlaylistStore(store: settings, secrets: secrets, ledger: InMemoryStore())
        first.add(
            Playlist(id: "x", name: "Zugang", kind: .xtream(server: server, username: "kunde42")),
            password: "geheim"
        )

        let second = PlaylistStore(store: settings, secrets: secrets, ledger: InMemoryStore())

        #expect(second.playlists.first?.kind == .xtream(server: server, username: "kunde42"))
        #expect(second.password(for: "x") == "geheim")
    }

    @Test("With the list its credentials disappear too")
    func credentialsRemovedWithPlaylist() {
        // Otherwise the password would outlive the entry through which you could delete it.
        let (store, _, _) = makeStore()
        store.add(
            Playlist(
                id: "x",
                name: "Zugang",
                kind: .xtream(server: URL(string: "http://a")!, username: "kunde")
            ),
            password: "geheim"
        )

        store.remove("x")

        #expect(store.credentials(for: "x") == nil)
    }

    @Test("Changed credentials also appear in the list's entry")
    func credentialsUpdateKind() {
        let (store, _, _) = makeStore()
        let server = URL(string: "http://a")!
        store.add(Playlist(id: "x", name: "Z", kind: .xtream(server: server, username: "alt")))

        store.setCredentials(XtreamCredentials(username: "neu", password: "pw"), for: "x")

        #expect(store.playlists.first?.kind == .xtream(server: server, username: "neu"))
        #expect(store.credentials(for: "x") == XtreamCredentials(username: "neu", password: "pw"))
    }

    // MARK: - Favoriten

    @Test("A favorite stays when the channel sits elsewhere after reloading")
    func favoriteSurvivesReorder() {
        // The core of the whole question: the ID from the file contains the
        // running number. If the provider inserts a channel at the top,
        // everything behind it shifts — with the ID as the key, the
        // favourite would afterwards point at the wrong channel.
        let (store, _, _) = makeStore()
        let before = channel("Das Nordlicht HD", list: "a", ordinal: 3)

        store.setFavorite(true, for: before)

        let after = channel("Das Nordlicht HD", list: "a", ordinal: 17)
        #expect(before.id != after.id, "the identifier is really a different one")
        #expect(store.isFavorite(after))
    }

    @Test("A favorite also applies in another list")
    func favoriteAcrossPlaylists() {
        // Wer den Anbieter wechselt, will seine Favoriten behalten.
        let (store, _, _) = makeStore()

        store.setFavorite(true, for: channel("Das Nordlicht", list: "alt", ordinal: 1))

        #expect(store.isFavorite(channel("Das Nordlicht", list: "neu", ordinal: 88)))
    }

    @Test("Spelling, umlauts and punctuation yield the same favorite")
    func favoriteKeyNormalisation() {
        // Every provider writes the same channel differently — but it is
        // the same channel in the same variant.
        let key = PlaylistStore.favoriteKey(forName: "Das Nordlicht HD")

        #expect(PlaylistStore.favoriteKey(forName: "das nordlicht hd") == key)
        #expect(PlaylistStore.favoriteKey(forName: "Das-Nordlicht | HD") == key)
        #expect(PlaylistStore.favoriteKey(forName: "DAS  NORDLICHT  HD") == key)
        #expect(PlaylistStore.favoriteKey(forName: "ZINNE") != key)
    }

    /// **The on-device finding from 2026-08-15, pinned down as a regression:** "KopruHaber
    /// HD" as a favourite marked UHD, FHD and HEVC as well, because the
    /// ID cut off the quality suffix. The viewer deliberately chooses
    /// exactly one variant.
    @Test("Quality variants of the same channel are favorites of their own")
    func qualityVariantsAreDistinctFavourites() {
        let hd = PlaylistStore.favoriteKey(forName: "KopruHaber HD")

        #expect(PlaylistStore.favoriteKey(forName: "KopruHaber UHD") != hd)
        #expect(PlaylistStore.favoriteKey(forName: "KopruHaber FHD") != hd)
        #expect(PlaylistStore.favoriteKey(forName: "KopruHaber HEVC") != hd)
        #expect(PlaylistStore.favoriteKey(forName: "KopruHaber (1080p)") != hd)
        // Only the truly identical variant shares the ID.
        #expect(PlaylistStore.favoriteKey(forName: "KOPRUHABER | HD") == hd)
    }

    /// **The third store is the same one**, because favourites have lived in the
    /// ``Core/StillLedger`` since AP42 and no longer with the lists. A second catalog with a
    /// fresh ledger would be a different person and not the same TV after the
    /// restart.
    @Test("A favorite survives saving and loading")
    func favoriteRoundTrip() {
        let settings = InMemoryStore()
        let secrets = InMemoryStore()
        let ledger = InMemoryStore()

        PlaylistStore(store: settings, secrets: secrets, ledger: ledger)
            .setFavorite(true, for: channel("Avena", list: "a", ordinal: 2))

        let reloaded = PlaylistStore(store: settings, secrets: secrets, ledger: ledger)

        #expect(reloaded.isFavorite(channel("Avena", list: "a", ordinal: 40)))
    }

    @Test("A favorite can be removed again")
    func toggleFavorite() {
        let (store, _, _) = makeStore()
        let avena = channel("Avena", list: "a", ordinal: 1)

        store.toggleFavorite(avena)
        #expect(store.isFavorite(avena))

        store.toggleFavorite(avena)
        #expect(!store.isFavorite(avena))
        #expect(store.favorites.isEmpty)
    }

    @Test("A channel that no longer exists loses its favorite")
    func pruneRemovesGhosts() {
        // Otherwise over the years a favourites list would pile up of channels that
        // no provider carries any more — and a new provider with a channel that happens to be
        // named the same would be handed the old favourite.
        let (store, _, _) = makeStore()
        let avena = channel("Avena", list: "a", ordinal: 1)
        let disabled = channel("Alter Sender", list: "a", ordinal: 2)
        store.setFavorite(true, for: avena)
        store.setFavorite(true, for: disabled)

        store.pruneFavorites(against: [avena])

        #expect(store.isFavorite(avena))
        #expect(!store.isFavorite(disabled))
        #expect(store.favorites.count == 1)
    }

    @Test("A failed fetch deletes no favorites")
    func pruneIgnoresEmptyReload() {
        // If the provider were briefly unreachable, the cleanup would otherwise silently
        // clear everything out.
        let (store, _, _) = makeStore()
        store.setFavorite(true, for: channel("Avena", list: "a", ordinal: 1))

        store.pruneFavorites(against: [])

        #expect(store.favorites.count == 1)
    }

    // MARK: - Merging

    @Test("A switched-off list yields no channels")
    func disabledPlaylistContributesNothing() {
        let (store, _, _) = makeStore()
        store.add(m3u("a", "A"))
        store.add(m3u("b", "B"))
        store.setEnabled(false, for: "b")

        let merged = store.merged([
            "a": [channel("AHORN", list: "a", ordinal: 1)],
            "b": [channel("ZINNE", list: "b", ordinal: 1)],
        ])

        #expect(merged.map(\.name) == ["AHORN"])
    }

    @Test("Two lists with overlapping channels yield each channel once")
    func mergeRemovesDuplicates() {
        // Since 2026-08-15. "the same channel" means: same name including the
        // quality suffix. "Zinne HD" from the second list is a variant of its own
        // and stays — before, it disappeared behind the "Zinne"
        // of the higher-ranked list, and the viewer never got to
        // see the variant. Only the identically named "Zinne" drops out.
        let (store, _, _) = makeStore()
        store.add(m3u("a", "A"))
        store.add(m3u("b", "B"))

        let merged = store.merged([
            "a": [
                channel("AHORN", list: "a", ordinal: 1),
                channel("ZINNE", list: "a", ordinal: 2),
            ],
            "b": [
                channel("ZINNE", list: "b", ordinal: 1),
                channel("ZINNE HD", list: "b", ordinal: 2),
                channel("Avena", list: "b", ordinal: 3),
            ],
        ])

        #expect(merged.map(\.name) == ["AHORN", "ZINNE", "ZINNE HD", "Avena"])
    }

    @Test("With duplicates the list higher up wins")
    func mergeRespectsRank() {
        // The ranking is the only reason why the user sorts.
        let (store, _, _) = makeStore()
        store.add(m3u("gut", "Guter Anbieter"))
        store.add(m3u("schlecht", "Ersatz"))

        let merged = store.merged([
            "gut": [channel("AHORN", list: "gut", ordinal: 1, url: "http://gut/ahorn")],
            "schlecht": [channel("AHORN", list: "schlecht", ordinal: 1, url: "http://mies/ahorn")],
        ])

        #expect(merged.count == 1)
        #expect(merged.first?.streamURL.absoluteString == "http://gut/ahorn")

        store.move("schlecht", to: 0)
        let after = store.merged([
            "gut": [channel("AHORN", list: "gut", ordinal: 1, url: "http://gut/ahorn")],
            "schlecht": [channel("AHORN", list: "schlecht", ordinal: 1, url: "http://mies/ahorn")],
        ])

        #expect(after.first?.streamURL.absoluteString == "http://mies/ahorn")
    }

    @Test("Two resolutions of the same channel within one list both stay")
    func mergeKeepsVariantsWithinOnePlaylist() {
        // The user should be able to switch away when one resolution stutters. Across
        // lists the same thing would be a useless duplicate.
        let (store, _, _) = makeStore()
        store.add(m3u("a", "A"))

        let merged = store.merged([
            "a": [
                channel("Das Nordlicht (1080p)", list: "a", ordinal: 1, url: "http://a/hd"),
                channel("Das Nordlicht (576p)", list: "a", ordinal: 2, url: "http://a/sd"),
            ]
        ])

        #expect(merged.count == 2)
    }

    @Test("The truly identical entry comes only once even within a list")
    func mergeRemovesExactDuplicates() {
        let (store, _, _) = makeStore()
        store.add(m3u("a", "A"))

        let merged = store.merged([
            "a": [
                channel("AHORN", list: "a", ordinal: 1, url: "http://a/ahorn"),
                channel("AHORN", list: "a", ordinal: 2, url: "http://a/ahorn"),
            ]
        ])

        #expect(merged.count == 1)
    }

    @Test("Merged channels carry their favorites")
    func mergeMarksFavorites() {
        // The marker was set in another list and still applies here —
        // but only for the same variant: "Avena HD" no longer marks the plain
        // "Avena" since 2026-08-15. (on-device finding, KopruHaber).
        let (store, _, _) = makeStore()
        store.add(m3u("a", "A"))
        store.setFavorite(true, for: channel("Avena HD", list: "irgendwo", ordinal: 9))

        let merged = store.merged([
            "a": [
                channel("AHORN", list: "a", ordinal: 1),
                channel("Avena", list: "a", ordinal: 2),
                channel("Avena HD", list: "a", ordinal: 3),
            ]
        ])

        #expect(merged.filter(\.isFavorite).map(\.name) == ["Avena HD"])
    }

    @Test("A ghost favorite creates no channel out of nothing")
    func ghostFavoriteAddsNothing() {
        let (store, _, _) = makeStore()
        store.add(m3u("a", "A"))
        store.setFavorite(true, for: channel("Abgeschalteter Sender", list: "a", ordinal: 1))

        let merged = store.merged(["a": [channel("AHORN", list: "a", ordinal: 1)]])

        #expect(merged.map(\.name) == ["AHORN"])
        #expect(merged.allSatisfy { !$0.isFavorite })
    }

    @Test("Channels of a list that is not stored are skipped")
    func mergeIgnoresUnknownPlaylists() {
        // Occurs when a list is deleted while its fetch is still running.
        let (store, _, _) = makeStore()
        store.add(m3u("a", "A"))

        let merged = store.merged([
            "a": [channel("AHORN", list: "a", ordinal: 1)],
            "geloescht": [channel("ZINNE", list: "geloescht", ordinal: 1)],
        ])

        #expect(merged.map(\.name) == ["AHORN"])
    }

    @Test("The order within a list is preserved")
    func mergeKeepsChannelOrder() {
        // With many providers the file's order is the channel number
        // that the user knows from cable TV. Sorting would be wrong.
        let (store, _, _) = makeStore()
        store.add(m3u("a", "A"))
        let names = ["Das Nordlicht", "ZINNE", "RENDAL", "Sela.1", "Prisma"]

        let merged = store.merged([
            "a": names.enumerated().map { channel($1, list: "a", ordinal: $0) }
        ])

        #expect(merged.map(\.name) == names)
    }

    @Test("A list without a fetch result leaves the others untouched")
    func mergeToleratesMissingResult() {
        let (store, _, _) = makeStore()
        store.add(m3u("a", "A"))
        store.add(m3u("b", "B"))

        let merged = store.merged(["b": [channel("ZINNE", list: "b", ordinal: 1)]])

        #expect(merged.map(\.name) == ["ZINNE"])
    }
}
