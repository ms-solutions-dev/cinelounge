import Core
import Foundation
import RatingsKit
import Testing

@testable import Features

/// Sorting — the three states and the order within a series.
@Suite("Sorting")
/// On the main actor, because the rules under test live there (AP15,
/// 2026-09-02): the warning gate turns "nonisolated calls MainActor" into a
/// failure — and in substance it always was one.
@MainActor
struct SortRulesTests {

    typealias Order = LibraryModel.SortOrder

    // MARK: - The sort order outlasts the section

    static func library(_ id: String, _ kind: Core.Library.Kind) -> Core.Library {
        Core.Library(id: id, name: id, kind: kind)
    }

    /// **The finding from the test report:** Whoever chooses a sort order finds it
    /// again at the next opening — otherwise one has to set it anew every time.
    @Test("The chosen order comes back as it was")
    func chosenOrderSurvives() {
        let store = InMemoryStore()
        let movies = Self.library("filme", .movies)
        let chosen = Order(sorting: .rating, ascending: false, isExplicit: true)

        LibraryModel.saveOrder(chosen, for: movies, to: store)

        #expect(LibraryModel.loadOrder(for: movies, from: store) == chosen)
    }

    /// **Separate per area**, and that is the explicit reason: "By year"
    /// makes sense for movies and perhaps not for home videos.
    @Test("A choice for movies does not change series and home videos")
    func areasAreSeparate() {
        let store = InMemoryStore()
        LibraryModel.saveOrder(
            Order(sorting: .dateAdded, ascending: false, isExplicit: true),
            for: Self.library("filme", .movies), to: store
        )

        let allSeries = Self.library("serien", .series)
        let homeVideos = Self.library("heim", .homeVideos)
        #expect(LibraryModel.loadOrder(for: allSeries, from: store) == Order.standard(for: .series))
        #expect(
            LibraryModel.loadOrder(for: homeVideos, from: store) == Order.standard(for: .homeVideos)
        )
    }

    /// **A provider's sections share one key.** A provider
    /// brings fifty of them; fifty keys would mean setting the same
    /// setting by hand fifty times.
    @Test("The sections of a provider library share their sorting")
    func vodCategoriesShareTheirSorting() {
        #expect(
            LibraryModel.sortScope(forLibraryID: "liste1|vod|action")
                == LibraryModel.sortScope(forLibraryID: "liste1|vod|komoedie")
        )
        // Two providers stay separate, and a library is not a VOD section.
        #expect(
            LibraryModel.sortScope(forLibraryID: "liste1|vod|action")
                != LibraryModel.sortScope(forLibraryID: "liste2|vod|action")
        )
        #expect(LibraryModel.sortScope(forLibraryID: "guid-1234") == "guid-1234")
    }

    /// **What does not exist in this area counts as never remembered.** A
    /// rating for home videos would be an active state without a matching button
    /// — and that looks like a bug, not like an old setting.
    @Test("An order the section does not offer is discarded")
    func foreignOrderIsDropped() {
        let store = InMemoryStore()
        let movies = Self.library("misch", .movies)
        LibraryModel.saveOrder(
            Order(sorting: .rating, ascending: false, isExplicit: true), for: movies, to: store)

        // The same key, another kind of library: there is no rating there.
        let homeVideos = Core.Library(id: "misch", name: "misch", kind: .homeVideos)
        #expect(
            LibraryModel.loadOrder(for: homeVideos, from: store) == Order.standard(for: .homeVideos)
        )
    }

    /// The third press restores the default — and that is deleted,
    /// not stored. Otherwise one could no longer tell whether someone
    /// chose it or never set anything.
    @Test("Back to the default clears the entry")
    func returningToDefaultClearsTheEntry() {
        let store = InMemoryStore()
        let movies = Self.library("filme", .movies)
        LibraryModel.saveOrder(
            Order(sorting: .rating, ascending: false, isExplicit: true), for: movies, to: store)

        LibraryModel.saveOrder(Order.standard(for: .movies), for: movies, to: store)

        #expect(LibraryModel.loadOrder(for: movies, from: store) == Order.standard(for: .movies))
        #expect((try? store.value(for: LibraryModel.sortStorageKey(for: movies))) == nil)
    }

    /// Nonsense in memory must not put the view into a state
    /// it cannot draw.
    @Test("What cannot be read counts as nothing")
    func garbageIsIgnored() {
        let store = InMemoryStore()
        let movies = Self.library("filme", .movies)
        try? store.set("", for: LibraryModel.sortStorageKey(for: movies))
        #expect(LibraryModel.loadOrder(for: movies, from: store) == Order.standard(for: .movies))

        try? store.set("gibtsnicht:auf", for: LibraryModel.sortStorageKey(for: movies))
        #expect(LibraryModel.loadOrder(for: movies, from: store) == Order.standard(for: .movies))
    }

    // MARK: - The last chosen item of the settings

    /// **Diagnostics in particular is rarely needed once and mostly ten times in a row**
    /// — and landed at the top again each time.
    @Test("Settings open at the remembered item")
    func settingsOpenWhereTheyWereLeft() {
        let store = InMemoryStore()
        SettingsSection.diagnostics.save(to: store)

        #expect(SettingsSection.load(from: store) == .diagnostics)
    }

    @Test("Without a memory they open at the channel lists")
    func settingsWithoutMemory() {
        #expect(SettingsSection.load(from: InMemoryStore()) == .playlists)
    }

    /// A point that no longer exists counts as never remembered — otherwise the
    /// list would point to something it cannot display.
    @Test("An item that no longer exists is discarded")
    func settingsDropUnknownSection() {
        let store = InMemoryStore()
        try? store.set("gibtsnicht", for: SettingsSection.storageKey)

        #expect(SettingsSection.load(from: store) == .playlists)
    }

    // MARK: - Three states

    /// **One press sorts, the second reverses, the third switches off.** The
    /// third state is the way back that such bars otherwise never have.
    @Test("The same button three times leads back to the default")
    func threeTapsReturnToDefault() {
        let standard = Order.standard(for: .movies)
        #expect(standard.sorting == .title)
        #expect(standard.isExplicit == false)

        let first = LibraryModel.next(after: standard, tapping: .rating, in: .movies)
        #expect(first == Order(sorting: .rating, ascending: false, isExplicit: true))

        let second = LibraryModel.next(after: first, tapping: .rating, in: .movies)
        #expect(second == Order(sorting: .rating, ascending: true, isExplicit: true))

        let third = LibraryModel.next(after: second, tapping: .rating, in: .movies)
        #expect(third == standard)
    }

    /// **The first direction is not always ascending.** For rating and
    /// date one wants the best and the newest first — whoever starts
    /// rigidly ascending shows the worst movies on the first press of "Rating".
    @Test("Every order starts in the direction one expects")
    func firstDirectionIsTheExpectedOne() {
        let standard = Order.standard(for: .movies)

        #expect(LibraryModel.next(after: standard, tapping: .title, in: .movies).ascending)
        #expect(!LibraryModel.next(after: standard, tapping: .rating, in: .movies).ascending)
        #expect(!LibraryModel.next(after: standard, tapping: .dateAdded, in: .movies).ascending)
    }

    /// Another button starts from scratch and does not take over the direction of the
    /// previous one — otherwise after "Rating ascending" "A–Z" would be reversed too.
    @Test("A different button starts over")
    func anotherButtonStartsOver() {
        let standard = Order.standard(for: .movies)
        let reversed = LibraryModel.next(
            after: LibraryModel.next(after: standard, tapping: .rating, in: .movies),
            tapping: .rating, in: .movies)
        #expect(reversed.ascending)

        let title = LibraryModel.next(after: reversed, tapping: .title, in: .movies)
        #expect(title == Order(sorting: .title, ascending: true, isExplicit: true))
    }

    /// **The default itself has only two states.** For it
    /// "switch off" and "restore" are the same thing; a third press that changes
    /// nothing would look like a stuck button.
    @Test("The default reverses and comes back")
    func defaultSortingHasTwoStates() {
        let standard = Order.standard(for: .movies)

        let first = LibraryModel.next(after: standard, tapping: .title, in: .movies)
        #expect(first == Order(sorting: .title, ascending: true, isExplicit: true))

        let second = LibraryModel.next(after: first, tapping: .title, in: .movies)
        #expect(second.ascending == false)

        let third = LibraryModel.next(after: second, tapping: .title, in: .movies)
        #expect(third == standard)
    }

    /// Home videos open by recording date, not by title — and the
    /// third press leads back there and not into the alphabet.
    @Test("Home videos return to their own default")
    func homeVideosHaveTheirOwnDefault() {
        let standard = Order.standard(for: .homeVideos)
        #expect(standard.sorting == .recorded)

        let cycled = LibraryModel.next(
            after: LibraryModel.next(after: standard, tapping: .title, in: .homeVideos),
            tapping: .title, in: .homeVideos)
        #expect(LibraryModel.next(after: cycled, tapping: .title, in: .homeVideos) == standard)
    }

    // MARK: - Rows

    static func film(_ title: String, _ year: Int?) -> MediaItem {
        MediaItem(id: title, kind: .movie, title: title, year: year)
    }

    /// **The case from the test report, on real titles of the catalog.**
    /// Alphabetically, "… der Moosturm" (2003) stands before "… der Spiegel von Orbel" (1996).
    @Test("A series is ordered by release, not alphabetically")
    func seriesGoByRelease() {
        let alphabetical = [
            Self.film("Lenno Varsk und der Bund der Störche", 2006),
            Self.film("Lenno Varsk und der Moosturm", 2003),
            Self.film("Lenno Varsk und der Nebelgraf", 2008),
            Self.film("Lenno Varsk und der Spiegel von Orbel", 1996),
            Self.film("Lenno Varsk und der Wächter von Drumel", 1999),
            Self.film("Lenno Varsk und die Halle des Raunens", 1998),
        ]
        let ordered = LibraryModel.ordered(
            alphabetical, by: .standard(for: .movies))

        #expect(ordered.map(\.year) == [1996, 1998, 1999, 2003, 2006, 2008])
    }

    /// **Whoever explicitly chooses "A–Z" gets the strict alphabet.** The
    /// default is the smarter one, the choice the literal one.
    @Test("The explicit choice is taken literally")
    func explicitChoiceStaysLiteral() {
        let alphabetical = [
            Self.film("Lenno Varsk und der Moosturm", 2003),
            Self.film("Lenno Varsk und der Spiegel von Orbel", 1996),
        ]
        let explicit = Order(sorting: .title, ascending: true, isExplicit: true)

        #expect(LibraryModel.ordered(alphabetical, by: explicit) == alphabetical)
    }

    /// **The series stays in its place.** Sorting happens within the group;
    /// its position in the list is still determined by its first title — otherwise
    /// whole blocks would jump through the grid.
    @Test("Everything outside the series stays where it was")
    func othersKeepTheirPlace() {
        let items = [
            Self.film("Aurelia", 2010),
            Self.film("Lenno Varsk und der Moosturm", 2003),
            Self.film("Lenno Varsk und der Spiegel von Orbel", 1996),
            Self.film("Zarnow", 2004),
        ]
        let ordered = LibraryModel.ordered(items, by: .standard(for: .movies))

        #expect(ordered.map(\.title).first == "Aurelia")
        #expect(ordered.map(\.title).last == "Zarnow")
        #expect(ordered[1].year == 1996)
        #expect(ordered[2].year == 2003)
    }

    /// A shared word is not a series — "The Pakuro" and "The Keeper of the
    /// Millstones" share only the article.
    @Test("A shared word does not make a series")
    func oneSharedWordIsNoSeries() {
        let items = [
            Self.film("Der Hüter der Mühlen - Die Wanderer", 1999),
            Self.film("Der Pakuro", 1974),
        ]
        #expect(LibraryModel.ordered(items, by: .standard(for: .movies)) == items)
        #expect(LibraryModel.sharedPrefixLength("Der Pakuro", "Der Hüter der Mühlen") == 1)
    }

    /// **Without a year the order stays as it was.** Reading a missing year as
    /// zero would tear the title to the start of the series — and that would look
    /// like a sorting bug.
    @Test("A missing year does not upset anything")
    func missingYearKeepsItsPlace() {
        let items = [
            Self.film("Nova Tides: Episode IV", 1976),
            Self.film("Nova Tides: Episode V", nil),
            Self.film("Nova Tides: Episode VI", 1985),
        ]
        let ordered = LibraryModel.ordered(items, by: .standard(for: .movies))
        #expect(ordered.map(\.title) == items.map(\.title))
    }

    /// The separators of the titles do not count: "The Keeper of the Millstones - The
    /// Wanderers" and "The Keeper of the Millstones: The War of the Kelmarer" are
    /// the same series, although they are separated differently.
    @Test("Different separators do not split the series")
    func separatorsDoNotSplitTheSeries() {
        #expect(
            LibraryModel.sharedPrefixLength(
                "Der Hüter der Mühlen - Die Wanderer",
                // Five, not four: "The" counts — both titles introduce their
                // subtitle with the same article.
                "Der Hüter der Mühlen: Die Schlacht der Kelmarer") == 5)
    }
}

/// **What no longer applies after a playback** (roadmap AP3).
///
/// The finding was the same in four places: after leaving an episode the
/// button still shows the old state. This rule says what has to be discarded for that —
/// and, just as important, when nothing.
@Suite("Refreshing after playback")
/// On the main actor, because the rules under test live there (AP15,
/// 2026-09-02): the warning gate turns "nonisolated calls MainActor" into a
/// failure — and in substance it always was one.
@MainActor
struct PlaybackRefreshTests {

    static func target(
        itemID: String?, seriesID: String? = nil, kind: PlaybackTarget.Kind = .recording
    ) -> PlaybackTarget {
        PlaybackTarget(
            itemID: itemID,
            title: "Titel",
            url: URL(string: "http://example.invalid/a.mkv")!,
            decision: PlaybackDecision(
                engine: .native, delivery: .directPlay, reason: .nativeContainer),
            seriesID: seriesID,
            kind: kind
        )
    }

    /// **The episode and its series.** The episode changes its mark, the series
    /// its count of unwatched episodes — and thereby what its button offers.
    @Test("An episode makes itself and its series stale")
    func episodeInvalidatesItselfAndItsSeries() {
        let ids = PlaybackRefresh.staleIDs(after: Self.target(itemID: "folge-7", seriesID: "serie-1"))

        #expect(ids == ["folge-7", "serie-1"])
    }

    @Test("A movie makes only itself stale")
    func movieInvalidatesItself() {
        #expect(PlaybackRefresh.staleIDs(after: Self.target(itemID: "film-2")) == ["film-2"])
    }

    /// **For a channel nothing is discarded**, and that is not a special case:
    /// live targets carry no library identifier. If anything were reported here,
    /// every channel switch would trigger a refetch of the whole library.
    @Test("A channel leaves the library alone")
    func liveLeavesTheLibraryAlone() {
        let channels = Self.target(itemID: "kanal-3", seriesID: nil, kind: .live)

        #expect(PlaybackRefresh.staleIDs(after: channels).isEmpty)
    }

    @Test("Without an identifier there is nothing to discard")
    func withoutAnIDNothingIsStale() {
        #expect(PlaybackRefresh.staleIDs(after: Self.target(itemID: nil)).isEmpty)
    }
}

/// **What stays standing at the jump** (roadmap AP4).
///
/// "Skip Intro and Credits no longer appear" — the markers came from the
/// server, were translated correctly and then cleared away at every long jump.
/// They are caught up only on an episode change.
@Suite("Context on a jump")
/// On the main actor, because the rules under test live there (AP15,
/// 2026-09-02): the warning gate turns "nonisolated calls MainActor" into a
/// failure — and in substance it always was one.
@MainActor
struct PlayerContextTests {

    static func target(
        _ itemID: String?, url: String = "http://example.invalid/a.mkv"
    )
        -> PlaybackTarget
    {
        PlaybackTarget(
            itemID: itemID,
            title: "Titel",
            url: URL(string: url)!,
            decision: PlaybackDecision(
                engine: .native, delivery: .directPlay, reason: .nativeContainer)
        )
    }

    @Test("A jump within the same title keeps segments and cast")
    func seekKeepsContext() {
        let previous = Self.target("folge-1")
        // The same title, another address: that is exactly a long jump.
        let after = Self.target("folge-1", url: "http://example.invalid/a.mkv?start=600")

        #expect(PlayerModel.keepsContext(from: previous, to: after))
    }

    @Test("The next episode cleans up")
    func nextEpisodeClearsContext() {
        #expect(!PlayerModel.keepsContext(from: Self.target("folge-1"), to: Self.target("folge-2")))
    }

    /// Channels carry no identifier — two in a row are two things, and the
    /// cast of the previous one must not stay standing over the new picture.
    @Test("A channel switch cleans up although neither carries an identifier")
    func liveAlwaysClears() {
        #expect(!PlayerModel.keepsContext(from: Self.target(nil), to: Self.target(nil)))
    }
}

/// **What stands at the bottom right.** The rule stood twice — in the view and in the
/// focus —, and two copies of the same decision drift apart.
@Suite("Offer on screen")
/// On the main actor, because the rules under test live there (AP15,
/// 2026-09-02): the warning gate turns "nonisolated calls MainActor" into a
/// failure — and in substance it always was one.
@MainActor
struct PlayerOfferTests {

    @Test("The next episode beats the credits")
    func nextEpisodeWinsOverOutro() {
        #expect(
            PlayerScreen.offer(hasNextUp: true, hasNextEpisode: true, hasSkip: true) == .nextUp
        )
    }

    /// A movie has no next episode — then the spot belongs to
    /// skipping, even at the credits.
    @Test("Without a next episode skipping stays")
    func skipRemainsWithoutNextEpisode() {
        #expect(PlayerScreen.offer(hasNextUp: true, hasNextEpisode: false, hasSkip: true) == .skip)
        #expect(PlayerScreen.offer(hasNextUp: false, hasNextEpisode: true, hasSkip: true) == .skip)
    }

    @Test("The intro stands without competition")
    func introStandsAlone() {
        #expect(PlayerScreen.offer(hasNextUp: false, hasNextEpisode: false, hasSkip: true) == .skip)
    }

    @Test("Without either nothing is on screen")
    func nothingOffered() {
        #expect(PlayerScreen.offer(hasNextUp: false, hasNextEpisode: false, hasSkip: false) == .none)
    }
}

/// **Everything up to here as watched** (user request 2026-08-12).
///
/// "I'm at episode 65, in between there are over forty filler episodes, and I
/// mark 108." What is almost always meant is everything up to there — the confirmation prompt
/// must, however, know how many that is, and must not miscount.
@Suite("Episodes up to here")
/// On the main actor, because the rules under test live there (AP15,
/// 2026-09-02): the warning gate turns "nonisolated calls MainActor" into a
/// failure — and in substance it always was one.
@MainActor
struct PrecedingEpisodesTests {

    static func episode(_ number: Int, watched: Bool) -> MediaItem {
        MediaItem(
            id: "f\(number)", kind: .episode, title: "Folge \(number)",
            episodeNumber: number,
            progress: PlaybackProgress(position: 0, duration: 1400, isWatched: watched)
        )
    }

    @Test("What lies before and is unwatched is counted")
    func countsOnlyUnwatchedBefore() {
        let episodes = [
            Self.episode(1, watched: true), Self.episode(2, watched: false),
            Self.episode(3, watched: false), Self.episode(4, watched: false),
        ]

        let before = DetailModel.precedingUnwatched(before: episodes[3], in: episodes)

        #expect(before.map(\.id) == ["f2", "f3"])
    }

    /// What lies **after** the episode stays untouched — otherwise one
    /// press would mark the whole season.
    @Test("Later episodes are left out")
    func laterEpisodesAreUntouched() {
        let episodes = [Self.episode(1, watched: false), Self.episode(2, watched: false)]

        #expect(DetailModel.precedingUnwatched(before: episodes[0], in: episodes).isEmpty)
    }

    /// If everything before it is watched, there is nothing to ask — then the
    /// press silently marks only this episode.
    @Test("Without a gap nothing is asked")
    func nothingToAsk() {
        let episodes = [Self.episode(1, watched: true), Self.episode(2, watched: false)]

        #expect(DetailModel.precedingUnwatched(before: episodes[1], in: episodes).isEmpty)
    }

    @Test("An episode not in the list has nothing before it")
    func unknownEpisode() {
        let episodes = [Self.episode(1, watched: false)]

        #expect(DetailModel.precedingUnwatched(before: Self.episode(9, watched: false), in: episodes).isEmpty)
    }
}

/// **The German voices find their role** (user request 2026-08-12).
///
/// The two sources write roles differently — the media server appends
/// "(voice)" and joins several roles with slashes, AniList
/// lists them individually. Without this translation the second line would stay empty,
/// although both sides mean the same character.
@Suite("German voices")
/// On the main actor, because the rules under test live there (AP15,
/// 2026-09-02): the warning gate turns "nonisolated calls MainActor" into a
/// failure — and in substance it always was one.
@MainActor
struct GermanVoicesTests {

    static let voices = GermanVoices(byCharacter: [
        "haruto kagemura": VoiceCredit(name: "Lukas Fennrich", imageURL: nil),
        "ren kaito": VoiceCredit(name: "Matthis Kerber", imageURL: nil),
    ])

    @Test("The appended (voice) does not interfere")
    func voiceSuffixIsIgnored() {
        #expect(
            Self.voices.voice(forCharacter: "Haruto Kagemura (voice)")?.name == "Lukas Fennrich"
        )
    }

    /// One person often voices several roles. Then each counts individually — otherwise
    /// "Ren Taiga / Ren Kaito / Ren Sora" would find nothing, although one of them is there.
    @Test("Several roles in one line are looked up individually")
    func multipleRolesAreSplit() {
        #expect(
            Self.voices.voice(forCharacter: "Ren Taiga / Ren Kaito / Ren Sora (voice)")?.name
                == "Matthis Kerber"
        )
    }

    @Test("Case and margins do not count")
    func caseAndSpacingDoNotMatter() {
        #expect(Self.voices.voice(forCharacter: "  HARUTO KAGEMURA  ") != nil)
    }

    /// **Where there is none, it stays empty** — and that is the rule for
    /// everything that is not anime.
    @Test("Without a hit the second line is omitted")
    func withoutAMatchNothingIsShown() {
        #expect(Self.voices.voice(forCharacter: "Arno Distelfink") == nil)
        #expect(Self.voices.voice(forCharacter: nil) == nil)
        #expect(GermanVoices(byCharacter: [:]).isEmpty)
    }
}
