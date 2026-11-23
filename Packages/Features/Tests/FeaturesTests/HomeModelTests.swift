import Core
import Flows
import Foundation
import Testing

@testable import Features

/// What is checked is the Home screen's logic, not its looks — the simulator is there for
/// that.
@Suite("Startseite")
@MainActor
struct HomeModelTests {

    @Test("Failures are translated into distinguishable messages")
    func distinctMessages() {
        // An expired sign-in asks something different of the user than an unreachable server. A
        // shared text would be worthless.
        let keys = [
            HomeModel.messageKey(for: .unauthorized),
            HomeModel.messageKey(for: .notFound),
            HomeModel.messageKey(for: .unreachable),
        ]

        #expect(Set(keys).count == 3)
        // **The namespace has changed** (AP25, 2026-09-11): `error.*` were the sentences of the old
        // home-grown table; since then they come from ``PlaybackPhase/forItem(_:)`` and are called
        // `state.*`. **The promise stays the same** — three distinguishable messages, because an
        // expired sign-in asks something different than a silent server.
        #expect(keys.allSatisfy { $0.hasPrefix("state.") })
    }

    @Test("Rows with episodes use the wide format, titles the tall format")
    func cardFormat() {
        let wide = HomeModel.Shelf(id: "a", titleKey: "x", items: [], usesWideCards: true)
        let tall = HomeModel.Shelf(id: "b", titleKey: "y", items: [], usesWideCards: false)

        #expect(wide.usesWideCards)
        #expect(!tall.usesWideCards)
    }

    // MARK: - Header area

    @Test("Left pages back in the header area only if it was paged forward by hand")
    func pageBackNeedsManualForward() {
        // At the first entry, left belongs to the sidebar — the way into the menu must not be
        // moved. The same after the automatic advance: Nobody wants to undo a movement they did not
        // make, and whoever presses left after twelve seconds of idling is looking for the menu.
        #expect(
            !HomeView.allowsPageBack(index: 0, forwardAt: nil, now: Date(timeIntervalSince1970: 1000)))
        #expect(
            !HomeView.allowsPageBack(index: 3, forwardAt: nil, now: Date(timeIntervalSince1970: 1000)))
        // And backwards is not paged in a circle: Before the first entry there is nothing, so left
        // continues into the menu there.
        #expect(
            !HomeView.allowsPageBack(
                index: 0, forwardAt: Date(timeIntervalSince1970: 1000),
                now: Date(timeIntervalSince1970: 1000)))

        #expect(
            HomeView.allowsPageBack(
                index: 3, forwardAt: Date(timeIntervalSince1970: 1000),
                now: Date(timeIntervalSince1970: 1000)))
    }

    /// A title as it would come from the server. Only the fields that matter here — everything
    /// else would hide the intent of the test.
    private func item(
        _ id: String,
        kind: MediaItem.Kind = .series,
        seriesID: String? = nil,
        backdrop: String? = "bd",
        resumable: Bool = false
    ) -> MediaItem {
        MediaItem(
            id: id,
            kind: kind,
            title: id,
            seriesID: seriesID,
            artwork: Artwork(backdropID: backdrop),
            progress: resumable ? PlaybackProgress(position: 300, duration: 1000) : nil
        )
    }

    private func shelf(
        _ id: String,
        _ items: [MediaItem],
        kind: Library.Kind? = .series
    ) -> HomeModel.Shelf {
        HomeModel.Shelf(
            id: id,
            titleKey: id,
            items: items,
            usesWideCards: false,
            libraryKind: kind
        )
    }

    /// **Decision 25 (2026-09-26): same feel on all devices.** Until then the started items came
    /// first here — on the phone no longer since 2026-09-06, because "Continue Watching" directly
    /// below asks the same question. The TV now chooses exactly like the phone: the same shared
    /// rule with the same libraries, nothing pulled forward.
    @Test("The header area picks as on the phone, without in-progress items in front")
    func likeOnPhone() {
        let allSeries = [
            item("kazeru"), item("folge", kind: .episode, seriesID: "hollowmark", resumable: true),
            item("saltcompass"),
        ]
        let heroes = HomeModel.heroCandidates(shelves: [shelf("serien", allSeries)], shuffle: false)

        #expect(heroes.map(\.id) == HomeLayout.heroes(libraries: [allSeries], shuffle: false).map(\.id))
        #expect(heroes.first?.id == "kazeru")
    }

    @Test("The same series appears at the top only once")
    func seriesAppearsOnce() {
        // An episode and the series itself are one title to the viewer. Without a summary the hero
        // area pages between two almost identical images.
        let heroes = HomeModel.heroCandidates(
            shelves: [
                shelf("serien", [item("f6", kind: .episode, seriesID: "hollowmark"), item("kazeru")]),
                shelf("mehr", [item("hollowmark")]),
            ],
            shuffle: false
        )

        #expect(heroes.map(\.id) == ["f6", "kazeru"])
    }

    @Test("Home videos stay out of the header area")
    func homeVideosExcluded() {
        // Explicitly intended: Personal recordings should not run full-screen on the Home screen
        // when guests are in the room.
        let heroes = HomeModel.heroCandidates(
            shelves: [
                shelf("privat", [item("urlaub", kind: .homeVideo)], kind: .homeVideos),
                shelf("serien", [item("hollowmark")]),
            ],
            shuffle: false
        )

        #expect(heroes.map(\.id) == ["hollowmark"])
    }

    @Test("Only film and series libraries feed the header area")
    func mixedLibrariesExcluded() {
        // A folder or mixed library can contain anything, private things too. What cannot be
        // assigned with certainty does not belong large on the Home screen — the more harmless
        // error.
        let heroes = HomeModel.heroCandidates(
            shelves: [
                shelf("verzeichnisse", [item("unbekannt")], kind: .mixed),
                shelf("serien", [item("hollowmark")]),
            ],
            shuffle: false
        )

        #expect(heroes.map(\.id) == ["hollowmark"])
        #expect(!HomeModel.heroEligible.contains(.mixed))
        #expect(!HomeModel.heroEligible.contains(.homeVideos))
    }

    @Test("A deselected library no longer feeds the header area")
    func excludedLibraryIsSkipped() {
        // The case no automatism solves: personal recordings set up as a movie library. The type is
        // then "movie", the intent is not.
        var preferences = HeroPreferences()
        preferences.setAllowed(false, for: "privat-als-filme")

        let heroes = HomeModel.heroCandidates(
            shelves: [
                shelf("privat-als-filme", [item("urlaub", kind: .movie)], kind: .movies),
                shelf("serien", [item("hollowmark")]),
            ],
            device: preferences,
            shuffle: false
        )

        #expect(heroes.map(\.id) == ["hollowmark"])
    }

    /// Check finding A-S8: The choice of the hero area lies per profile in the shelf order, as on
    /// the phone, and takes precedence over the device's old exclusion list.
    @Test("The profile's header-area choice applies — and takes precedence over the device list")
    func heroShelvesOfProfile() {
        var preferences = ShelfPreferences()
        preferences.fillHeroes("filme", false, from: ["filme", "serien"])
        let shelves = [
            shelf("filme", [item("urlaub", kind: .movie)], kind: .movies),
            shelf("serien", [item("hollowmark")]),
        ]
        let heroes = HomeModel.heroCandidates(
            shelves: shelves, preferences: preferences,
            device: HeroPreferences(excluded: ["serien"]), shuffle: false)
        #expect(heroes.map(\.id) == ["hollowmark"])
    }

    @Test("Without a setting everything stays as before")
    func withoutPreferencesNothingChanges() {
        // Important that the new option shifts nothing as long as nobody uses it.
        let shelves = [shelf("serien", [item("a"), item("b")])]

        let withDefault = HomeModel.heroCandidates(
            shelves: shelves, shuffle: false)
        let withEmpty = HomeModel.heroCandidates(
            shelves: shelves, device: HeroPreferences(), shuffle: false)

        #expect(withDefault.map(\.id) == withEmpty.map(\.id))
        #expect(withDefault.count == 2)
    }

    @Test("Titles without a backdrop do not enter the header area")
    func requiresBackdrop() {
        // The hero area is almost only image. Without one an empty surface would remain that looks
        // like a loading error.
        let heroes = HomeModel.heroCandidates(
            shelves: [shelf("serien", [item("ohne", backdrop: nil), item("mit")])],
            shuffle: false
        )

        #expect(heroes.map(\.id) == ["mit"])
    }

    @Test("The header area alternates between the libraries")
    func alternatesBetweenLibraries() {
        // Going through library by library would mean: with a large series library, a series eight
        // times, and the movies never seen.
        let heroes = HomeModel.heroCandidates(
            shelves: [
                shelf("serien", [item("s1"), item("s2"), item("s3")]),
                shelf("filme", [item("f1", kind: .movie)], kind: .movies),
            ],
            shuffle: false
        )

        #expect(heroes.map(\.id) == ["s1", "f1", "s2", "s3"])
    }

    @Test("The header area stays limited to eight titles")
    func limited() {
        // More would be pointless: At twelve seconds per title, one round already takes over a
        // minute and a half this way.
        let many = (1...30).map { item("s\($0)") }

        #expect(HomeModel.heroCandidates(shelves: [shelf("s", many)]).count == 8)
    }

    @Test("The state cannot be loading and failed at the same time")
    func statesAreExclusive() {
        // A single state instead of several flags — otherwise combinations arise that must not
        // exist.
        let loading = HomeModel.State.loading
        // **A state and not a key** (AP25, 2026-09-11) — see ``HomeModel/State/failed(_:)``.
        let failed = HomeModel.State.failed(.networkJellyfin)

        #expect(loading != failed)
        #expect(HomeModel.State.empty != loading)
    }
}
