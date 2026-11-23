import Core
import Foundation
import Testing

@testable import PortalKit

/// The run against the **running** service.
///
/// **Off by default.** These checks need a home network, a running service and a portal that is answering
/// right now — conditions that do not hold on a build server and whose absence says nothing about the
/// source code.
///
/// Switch on with the address:
///
///     PORTALE_BRUECKE=http://<portals-host>:8099 swift test
///     PORTALE_BRUECKE=http://<home-server>:8100 PORTALE_MERKMAL=… swift test
///
/// **The same series against both services, and that is the point (2026-09-12).** The claim of the
/// switchover is: the CineLounge server answers the same questions as the bridge, and the app notices no
/// difference. A second test series for the server would **not** check this claim — it would only check
/// that someone wrote a second series to match. That is why there is only one more optional field here:
/// ``PORTALE_MERKMAL``, the device attribute. If it is missing, the service is the bridge.
///
/// They check what a test double fundamentally cannot: whether the form the service sends is the form this
/// source code reads. That is exactly where the errors sit that a green check otherwise overlooks.
@Suite(
    "Against the running service",
    .enabled(if: ProcessInfo.processInfo.environment["PORTALE_BRUECKE"] != nil)
)
struct PortalLiveTests {

    private var source: PortalSource { Self.source() }

    /// The source from the environment — with attribute, if one is there.
    static func source() -> PortalSource {
        let environment = ProcessInfo.processInfo.environment
        let bridgeAddress = environment["PORTALE_BRUECKE"]!
        return PortalSource(
            bridge: PortalBridge(
                basis: URL(string: bridgeAddress)!, trait: environment["PORTALE_MERKMAL"]))
    }

    @Test("The bridge names its portals")
    func portals() async throws {
        let found = try await source.availablePortals()
        #expect(!found.isEmpty)
        for portal in found {
            print(
                "   \(portal.ready ? "✓" : "✗") \(portal.id) — \(portal.name)\(portal.reason.map { " (\($0))" } ?? "")"
            )
        }
    }

    @Test("Entry points become libraries")
    func libraries() async throws {
        let found = try await source.libraries()
        #expect(!found.isEmpty)
        // Every identifier must be decomposable again — otherwise the jump from the sidebar leads nowhere.
        for library in found {
            #expect(PortalLibraryID(library.id) != nil, "unreadable identifier: \(library.id)")
        }
        print("   \(found.count) entry points: \(found.prefix(6).map(\.name).joined(separator: ", ")) …")
    }

    @Test("The whole way: list, children, sources, address")
    func walkthrough() async throws {
        let source = self.source
        let libraries = try await source.libraries()
        let incoming = try #require(libraries.first { $0.name.contains("Folgen") } ?? libraries.first)

        let items = try await source.items(in: incoming.id, filter: ItemFilter(sortBy: .dateAdded))
        #expect(!items.isEmpty, "\"\(incoming.name)\" came back empty")
        let first = try #require(items.first)
        print("   \(items.count) entries in \"\(incoming.name)\" — first: \(first.title) (\(first.kind))")

        // What the list fetched, the detail page must find right afterwards. That is not convenience but the only
        // possibility: a portal script has no call for a single entry.
        let again = try await source.item(id: first.id)
        #expect(again.title == first.title)

        // Bis zu einer Folge hinabsteigen.
        var entry = first
        var slots = 0
        while entry.kind != .episode, entry.kind != .movie, slots < 3 {
            let children = try await source.children(of: entry.id)
            guard let next = children.first else { break }
            entry = next
            slots += 1
        }
        print("   Target after \(slots) steps: \(entry.title) (\(entry.kind))")

        let host = try await source.sources(forItem: entry.id)
        #expect(!host.isEmpty, "no source for \(entry.title)")
        print("   Host: \(host.map(\.name).joined(separator: ", "))")

        // The decision plays no role here: a portal delivers a finished file, and `/play` knows no start point —
        // that is why `canStartAtOffset` is false.
        let decision = PlaybackDecision(
            engine: .native, delivery: .directPlay, reason: .nativeContainer)
        let address = try await source.streamURL(for: entry.id, decision: decision)
        // **The pass-through is checked, not its name (2026-09-12).** Here stood `address.path == "/play"`, and
        // that had been wrong for some time: the bridge passes through via `/stream`, the server via `/stream`.
        // Because this series is off by default, nobody noticed.
        //
        // The promise is different anyway and holds for both services: **the playback address points to the
        // service itself, never to the host.** A redirect would carry no headers and could not give a reason for a
        // refusal — the app needs both. The path name may change, the machine may not.
        let service = source.bridgeAddress
        #expect(address.host() == URL(string: service)?.host())
        #expect(address.port == URL(string: service)?.port)
        print("   Abspieladresse: \(address.absoluteString.prefix(90))")

        // **And it is fetched, not just built** (viewer finding 2026-08-27, "episodes generally cannot be played"):
        // until here this run checked only that an address arises. It did arise — it just led nowhere, because
        // the portal appended its headers to the address after a `|` and nobody split them off. A check that does
        // not fetch the address cannot see that.
        //
        // It is fetched with the head of an Apple TV and only the first kilobyte: what matters is the host's
        // answer, not the video.
        var fetch = URLRequest(url: address)
        fetch.setValue("bytes=0-1024", forHTTPHeaderField: "Range")
        fetch.setValue(
            "AppleCoreMedia/1.0.0.21L227 (Apple TV; U; CPU OS 17_5 like Mac OS X)",
            forHTTPHeaderField: "User-Agent")
        let (data, reply) = try await URLSession.shared.data(for: fetch)
        let http = try #require(reply as? HTTPURLResponse)
        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? "—"
        print("   Fetch: \(http.statusCode) · \(contentType) · \(data.count) Bytes")
        #expect(
            (200...299).contains(http.statusCode),
            "The host answered with \(http.statusCode) instead of video")
        #expect(
            contentType.contains("video") || contentType.contains("mpegurl")
                || contentType.contains("octet-stream"),
            "The host delivered \(contentType) — no player plays that")
        #expect(!data.isEmpty, "The response was empty")
    }

    /// **Where the bridge names an image, an address must arise too.**
    ///
    /// The finding of 2026-08-28 was "images are not loaded cleanly for portals", and the suspicion was close
    /// that the app loads them wrongly. It does not: most of the portal scripts' lists carry **no** images at all —
    /// at Serieshub only "Discover", at Animehub only "Popular Series". This check separates the two. If it
    /// finds a level with images and no address came of it, it would be the app; if it finds not a single one,
    /// it is the source — and that then stands here in black and white instead of in a suspicion.
    @Test("A named image address becomes a retrievable one")
    func imagesComeThrough() async throws {
        let source = self.source
        let libraries = try await source.libraries()

        var withImage: [MediaItem] = []
        var searched: [String] = []
        for library in libraries.prefix(8) {
            let items = try await source.items(in: library.id, filter: ItemFilter())
            let match = items.filter { $0.artwork.posterID != nil }
            searched.append("\(library.name): \(match.count)/\(items.count)")
            if !match.isEmpty, withImage.isEmpty { withImage = match }
        }
        print("   " + searched.joined(separator: " · "))

        let first = try #require(
            withImage.first,
            "Not a single level named an image — then the source is at fault, not the app")
        let address = try #require(
            source.imageURL(itemID: first.artwork.posterID!, kind: .primary, width: 400, tag: nil),
            "The bridge named an image, but no address resulted")

        let (data, reply) = try await URLSession.shared.data(from: address)
        let http = try #require(reply as? HTTPURLResponse)
        print("   Image of \"\(first.title)\": \(http.statusCode) · \(data.count) Bytes")
        #expect((200...299).contains(http.statusCode))
        #expect(data.count > 1000, "That was no image but an error page")
    }

    /// **The finding from the device, recorded as a check.** "Popular Series" at Serieshub are genres, not
    /// series — they stood there as posters. What a level contains, the bridge has to say and the view has to
    /// draw accordingly.
    @Test("A menu level delivers folders, a catalog level titles")
    func levelsDiffer() async throws {
        let source = self.source
        let libraries = try await source.libraries()

        // **Anchored to the portal, not to the name.** "Popular Series" exists at Serieshub and at Animehub —
        // and it means different things there: at Serieshub it leads to genres (`showEntries`), at Animehub
        // directly to series (`showSeasons`). The first attempt of this check took the first name that matched and
        // failed. Exactly this ambiguity is why the target function decides and not the name of the entry point.
        func level(_ portal: String, _ name: String) async throws -> [MediaItem] {
            let target = try #require(
                libraries.first {
                    $0.name == name && PortalLibraryID($0.id)?.portal == portal
                })
            return try await source.level(target.id).items
        }

        let menu = try await level("serieshub", "Beliebte Serien")
        #expect(!menu.isEmpty)
        #expect(menu.allSatisfy { $0.kind == .folder }, "expected: all folders")
        print(
            "   \"Beliebte Serien\": \(menu.count) folders — \(menu.prefix(3).map(\.title).joined(separator: ", "))"
        )

        let catalog = try await level("serieshub", "Alle Serien")
        #expect(catalog.count > 1000)
        #expect(catalog.allSatisfy { $0.kind == .series }, "expected: all series")
        print("   \"Alle Serien\": \(catalog.count) titles")

        // And the way down must hold from a folder row.
        let folder = try #require(menu.first)
        let deeper = try #require(PortalSource.levelID(forItem: folder))
        let content = try await source.level(deeper).items
        print(
            "   \"\(folder.title)\" → \(content.count) entries (\(Set(content.map(\.kind)).map(String.init(describing:)).sorted().joined(separator: ", ")))"
        )
        #expect(!content.isEmpty)
    }

    /// Section headings belong in the folder list, not in the grid: as a tile without an image they would be a
    /// title that does not exist.
    @Test("Separator rows occur in the level, not in the titles")
    func separatorRowsOnlyInLevel() async throws {
        let source = self.source
        let libraries = try await source.libraries()
        guard
            let discover = libraries.first(where: {
                $0.name == "Entdecken" && PortalLibraryID($0.id)?.portal == "serieshub"
            })
        else { return }

        let all = try await source.level(discover.id).items
        let title = try await source.items(in: discover.id, filter: .default)
        let separator = all.filter { $0.kind == .separator }
        print(
            "   Discover: \(all.count) in the level, of which \(separator.count) separator rows → \(title.count) titles"
        )
        #expect(!separator.isEmpty)
        #expect(title.allSatisfy { $0.kind != .separator })
        #expect(title.count == all.count - separator.count)
    }

    @Test("The state goes there and comes back")
    func state() async throws {
        let source = self.source
        let libraries = try await source.libraries()
        let first = try #require(libraries.first { $0.name.contains("Folgen") } ?? libraries.first)
        let items = try await source.items(in: first.id, filter: .default)
        let target = try #require(items.first)

        // From a known state. The cleanup step at the end of this check marks the episode as watched — on the next
        // run it would rightly drop out of "Continue Watching", and the check would fail without anything being
        // wrong in the source code.
        try await source.setPlayed(false, for: target.id)
        try await source.report(
            progress: PlaybackProgress(position: 300, duration: 1500), for: target.id, isPaused: false)
        try await source.setFavorite(true, for: target.id)

        // The position report must not drag the favorite mark along.
        try await source.report(
            progress: PlaybackProgress(position: 420, duration: 1500), for: target.id, isPaused: false)

        let favorites = try await source.favorites()
        let remembered = try #require(favorites.first { $0.id == target.id })
        #expect(remembered.progress?.position == 420)
        #expect(remembered.isFavorite == true)

        let next = try await source.resumable(limit: 20)
        #expect(next.contains { $0.id == target.id })

        // Clean up again — a check should leave no state behind.
        try await source.setFavorite(false, for: target.id)
        try await source.setPlayed(true, for: target.id)
        print("   State went there and came back: \(target.title)")
    }
}

/// **Every portal, one level deeper from the root.**
///
/// The finding of 2026-08-28 was "I cannot navigate into one portal, with Serieshub and Animehub it works".
/// In the bridge's log there was only `/menu` for it, never a `/list` — so the error sat in the app and
/// not in the server. A check that treats every portal the same finds something like this before it shows
/// on the TV.
@Suite(
    "Every portal leads on from the root",
    .enabled(if: ProcessInfo.processInfo.environment["PORTALE_BRUECKE"] != nil)
)
struct PortalRootWalkthroughTests {

    private var source: PortalSource { PortalLiveTests.source() }

    @Test("From the root into the first level — for every ready portal")
    func rootLeadsOn() async throws {
        let source = self.source
        let portals = try await source.availablePortals().filter(\.ready)
        #expect(!portals.isEmpty)

        for portal in portals {
            let root = PortalSource.rootID(portal: portal.id)
            let top = try await source.level(root).items
            print("   \(portal.id): \(top.count) entry points")
            let first = try #require(top.first, "\(portal.id) has no entry point")

            // Exactly the chain that a press on the TV triggers.
            let deeper = try #require(
                PortalSource.levelID(forItem: first),
                "\(portal.id): \"\(first.title)\" leads into no level — exactly the symptom")
            let bottom = try await source.level(deeper).items
            print("      → \"\(first.title)\": \(bottom.count) entries")
            #expect(!bottom.isEmpty, "\(portal.id): nothing came under \"\(first.title)\"")
        }
    }
}

/// **Every list that hands out entries must remember them.**
///
/// A portal script has no call for a single title — ``item(id:)`` answers from memory and as a fallback from the
/// bridge's state. A list that does not store its entries thereby lays a mine: every title then costs an
/// additional call, and the one never touched fails completely.
///
/// On 2026-08-28 it came to that. `favorites()` and `resumable()` remembered nothing, and on the TV there was
/// "No answer. Is the server running, and is it on the same network?" — the detail page's catch-all error
/// that appears on every failure. The bridge had been answering in twenty milliseconds the whole time.
@Suite(
    "What a list yields, the detail page finds again",
    .enabled(if: ProcessInfo.processInfo.environment["PORTALE_BRUECKE"] != nil)
)
struct PortalMemoryTests {

    private var source: PortalSource { PortalLiveTests.source() }

    @Test("A favorite is retrievable individually afterwards")
    func favoriteIsRetrievable() async throws {
        let source = self.source
        let favorites = try await source.favorites()
        try #require(!favorites.isEmpty, "no favorite on the bridge — nothing to check")
        for entry in favorites {
            let again = try await source.item(id: entry.id)
            #expect(again.title == entry.title)
        }
    }

    @Test("A Continue Watching entry is retrievable individually afterwards")
    func continueWatchingIsRetrievable() async throws {
        let source = self.source
        let pending = try await source.resumable(limit: 20)
        try #require(!pending.isEmpty, "nothing started — nothing to check")
        for entry in pending {
            let again = try await source.item(id: entry.id)
            #expect(again.title == entry.title)
        }
    }

    /// **The finding of 2026-09-07, second part:** the **episode** resolved, the **series** did not — it was in no
    /// state, because nobody ever started it directly. Exactly it is the target as soon as "Continue Watching"
    /// leads from the episode to the series. The way back is the portal search, matched via the key.
    @Test("A series is retrievable without ever having been touched")
    func seriesWithoutProgress() async throws {
        let found = try await source.search(text: "Bloufeit")
        let series = try #require(
            found.first { PortalItemID($0.id)?.key == "serieshub:bloufeit:" },
            "Serieshub does not find \"Bloufeit\" right now — nothing to check")

        let fresh = self.source
        let again = try await fresh.item(id: series.id)
        #expect(again.title == "Bloufeit")
        #expect(again.kind == .series)
    }

    /// **The finding of 2026-09-07:** "Bloufeit" was on the phone's "Continue Watching" shelf and led to an error
    /// screen. The device's history carries only the identifier — no list that could have filled the memo.
    ///
    /// **The second source is the point of the check.** It has fetched nothing and remembered nothing; what it
    /// answers can only come from the bridge's state. The same situation as after an app restart.
    @Test("A started title is retrievable even without a list behind it")
    func withoutListFromProgress() async throws {
        let pending = try await source.resumable(limit: 5)
        try #require(!pending.isEmpty, "nothing started — nothing to check")

        let fresh = self.source
        for entry in pending {
            let again = try await fresh.item(id: entry.id)
            #expect(again.title == entry.title)
            #expect(again.kind == entry.kind)
        }
    }
}
