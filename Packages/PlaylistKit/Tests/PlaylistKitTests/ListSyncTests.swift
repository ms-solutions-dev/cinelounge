import Core
import Foundation
import Testing

@testable import PlaylistKit

/// Channel lists between two devices — the seam between list and cloud.
@Suite("Channel lists for syncing")
@MainActor
struct ListSyncTests {

    let panel = URL(string: "http://panel.example:8080")!
    let m3u = URL(string: "http://listen.example/get.php?username=max&password=geheim")!

    func catalog() -> PlaylistStore {
        PlaylistStore(store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore())
    }

    func filled() -> PlaylistStore {
        let catalog = catalog()
        let xtream = Playlist(name: "Anbieter", kind: .xtream(server: panel, username: "max"))
        catalog.add(xtream)
        catalog.setCredentials(
            XtreamCredentials(username: "max", password: "kennwort"), for: xtream.id)
        catalog.add(Playlist(name: "Liste", kind: .m3u(m3u)))
        return catalog
    }

    @Test("What is on one device is on the other afterwards")
    func backAndForth() {
        let here = filled()
        let there = catalog()
        #expect(there.adopt(here.channelListCredentials()) == 2)

        #expect(there.playlists.map(\.name).sorted() == ["Anbieter", "Liste"])
        let provider = there.playlists.first { $0.name == "Anbieter" }
        #expect(there.password(for: provider?.id ?? "") == "kennwort")
        let list = there.playlists.first { $0.name == "Liste" }
        #expect(list?.kind == .m3u(m3u))
    }

    /// **An M3U address carries the password as a query parameter.** The open field
    /// must not contain it — otherwise it would sit in plain text in the cloud, and the
    /// key would travel on from there into backups.
    @Test("The open address of an M3U list carries no password")
    func noPasswordInPlaintext() {
        let credentials = filled().channelListCredentials()
        for credential in credentials {
            #expect(credential.address?.absoluteString.contains("password") != true)
            #expect(!credential.name.contains("password"))
        }
        let list = credentials.first { $0.kind == .m3u }
        #expect(list?.address?.absoluteString == "http://listen.example/get.php")
        #expect(list?.secret == m3u.absoluteString)
        #expect(list?.user == "max")
    }

    /// **No address, no M3U list.** With M3U the address *is* the secret; if it is missing,
    /// there would be nothing to create — and a list that points at nothing looks
    /// like a broken provider.
    @Test("An M3U list without a secret is not created")
    func withoutAddress() {
        let there = catalog()
        let without = ChannelListAccess(
            key: "m3u|listen.example|max", name: "Liste", kind: .m3u,
            address: URL(string: "http://listen.example/get.php"), user: "max")
        #expect(there.adopt([without]) == 0)
        #expect(there.playlists.isEmpty)
    }

    /// An Xtream account without a password is very much created — it is a list that only
    /// lacks the login, and the viewer sees that.
    @Test("An Xtream access without a password is created anyway")
    func withoutPassword() {
        let there = catalog()
        let without = ChannelListAccess(
            key: "xtream|panel.example|max", name: "Anbieter", kind: .xtream,
            address: panel, user: "max")
        #expect(there.adopt([without]) == 1)
        #expect(there.playlists.count == 1)
        // ``add(_:password:)`` always creates credentials for a user name —
        // an empty password if there is none. What counts: none was guessed.
        #expect(there.password(for: there.playlists[0].id)?.isEmpty == true)
    }

    /// **Nothing is deleted on adoption.** A list that is here and not in the
    /// cloud can mean two things — "another device removed it" or
    /// "it was just created". The wrong answer takes someone's
    /// provider away.
    @Test("A list that exists only here stays")
    func nothingDisappears() {
        let here = filled()
        #expect(here.adopt([]) == 0)
        #expect(here.playlists.count == 2)
    }

    @Test("A second pass changes nothing")
    func twice() {
        let here = filled()
        let there = catalog()
        #expect(there.adopt(here.channelListCredentials()) == 2)
        #expect(there.adopt(here.channelListCredentials()) == 0)
    }

    /// A renamed or switched-off account arrives without the list being
    /// created anew — the key is the same.
    @Test("Renaming and switching off arrive")
    func changed() {
        let here = filled()
        let there = catalog()
        _ = there.adopt(here.channelListCredentials())

        var credentials = here.channelListCredentials()
        credentials = credentials.map { credential in
            credential.kind == .xtream
                ? ChannelListAccess(
                    key: credential.key, name: "Anbieter Neu", kind: credential.kind,
                    address: credential.address, user: credential.user, epg: credential.epg,
                    active: false, secret: credential.secret)
                : credential
        }
        #expect(there.adopt(credentials) == 1)
        let provider = there.playlists.first { $0.key.hasPrefix("xtream|") }
        #expect(provider?.name == "Anbieter Neu")
        #expect(provider?.isEnabled == false)
        #expect(there.playlists.count == 2)
    }

    /// The key is the one from AP42 — computer and account, not a rolled-dice ID.
    /// Without it the same list would get two entries on two devices.
    @Test("The key of an access is the list key")
    func key() {
        let credentials = filled().channelListCredentials()
        #expect(
            credentials.map(\.key).sorted() == [
                "m3u|listen.example|max", "xtream|panel.example|max",
            ])
    }
}

/// **An arrived list appears immediately and not only at the next launch**
/// (AP43, 2026-09-21).
///
/// The program keeps several ``PlaylistStore``s over **the same** store — `MainView`,
/// `PlaylistAccounts` and the startup. As long as only the UI writes, that
/// goes unnoticed: whoever writes also redraws. The iCloud sync, however, writes from
/// outside, and the catalog the viewer was looking at was a different one.
@Suite("The nudge to the other catalogs", .serialized)
@MainActor
struct ListWatchTests {

    /// Two views of one store — exactly the situation in the program.
    private func twoViews() -> (PlaylistStore, PlaylistStore) {
        let load = InMemoryStore()
        let isSecret = InMemoryStore()
        let ledger = InMemoryStore()
        return (
            PlaylistStore(store: load, secrets: isSecret, ledger: ledger),
            PlaylistStore(store: load, secrets: isSecret, ledger: ledger)
        )
    }

    @Test("What the sync puts in, the other catalog sees too")
    func arrivalReachesBoth() {
        let (sync, surface) = twoViews()
        #expect(surface.playlists.isEmpty)

        let arrived = ChannelListAccess(
            key: "xtream|panel.example|max", name: "Panel", kind: .xtream,
            address: URL(string: "https://panel.example"), user: "max",
            active: true, secret: "geheim")
        #expect(sync.adopt([arrived]) == 1)

        #expect(surface.playlists.map(\.name) == ["Panel"])
    }

    /// **No change, no call.** The sync runs at every launch and at every
    /// silent push; re-reading on every pass would redraw half the UI
    /// for nothing.
    @Test("A pass without a change nudges nobody")
    func noCallWithoutChange() {
        let (sync, surface) = twoViews()
        let credential = ChannelListAccess(
            key: "xtream|panel.example|max", name: "Panel", kind: .xtream,
            address: URL(string: "https://panel.example"), user: "max", active: true)
        #expect(sync.adopt([credential]) == 1)
        #expect(surface.playlists.count == 1)

        // The same account a second time — nothing to do.
        #expect(sync.adopt([credential]) == 0)
        #expect(surface.playlists.count == 1)
    }

    /// **A catalog that nobody holds any longer drops out.** The watcher keeps none
    /// alive; otherwise it would grow with every screen ever built.
    @Test("The watch keeps nobody alive")
    func weakPointers() {
        let previous = ListGuard.count
        var held: (PlaylistStore, PlaylistStore)? = twoViews()
        #expect(held != nil)
        #expect(ListGuard.count == previous + 2)

        held = nil
        #expect(ListGuard.count == previous)
    }
}
