import Core
import Testing

@testable import Features

/// Several Jellyfin libraries of the same kind on the TV (AP89, variant A).
///
/// **The finding:** the tab took the first library of its kind, and a second home video folder
/// was reachable only through its Home shelf. Now the title offers a choice — but only from two
/// libraries on; with one, nothing may change.
@Suite("Library choice")
struct LibraryChoiceTests {

    private static let family = Core.Library(id: "f1", name: "Family", kind: .homeVideos)
    private static let holiday = Core.Library(id: "h2", name: "Holiday 2025", kind: .homeVideos)
    private static let movies = Core.Library(id: "m1", name: "Movies", kind: .movies)
    private static let kids = Core.Library(id: "k1", name: "Kids movies", kind: .movies)
    private static let series = Core.Library(id: "s1", name: "Series", kind: .series)

    private static let server = [movies, family, series, holiday, kids]

    // MARK: - Which libraries a tab offers

    @Test("Candidates are the libraries of the kind, in server order")
    func candidatesKeepServerOrder() {
        #expect(LibraryChoice.candidates(Self.server, kind: .homeVideos) == [Self.family, Self.holiday])
        #expect(LibraryChoice.candidates(Self.server, kind: .movies) == [Self.movies, Self.kids])
    }

    /// **A0: the normal case stays as it was** — one library, no choice.
    @Test("A single library of a kind offers no choice")
    func singleLibraryOffersNoChoice() {
        #expect(!LibraryChoice.offersChoice(Self.server, kind: .series))
        #expect(LibraryChoice.offersChoice(Self.server, kind: .homeVideos))
        #expect(!LibraryChoice.offersChoice([], kind: .movies))
    }

    // MARK: - Which library opens

    @Test("Without a remembered choice the first library of the kind opens")
    func firstWithoutMemory() {
        #expect(LibraryChoice.resolve(Self.server, kind: .homeVideos, remembered: nil) == Self.family)
    }

    @Test("A remembered library opens the tab")
    func rememberedWins() {
        #expect(
            LibraryChoice.resolve(Self.server, kind: .homeVideos, remembered: "h2") == Self.holiday)
    }

    /// **Gone from the server — silently back to the first**, as before AP89.
    @Test("A remembered library that disappeared falls back to the first")
    func vanishedFallsBack() {
        #expect(
            LibraryChoice.resolve(Self.server, kind: .homeVideos, remembered: "gone") == Self.family)
    }

    /// A remembered identifier of another kind must not pull the tab into a foreign library.
    @Test("A remembered library of another kind is ignored")
    func otherKindIgnored() {
        #expect(
            LibraryChoice.resolve(Self.server, kind: .homeVideos, remembered: "k1") == Self.family)
    }

    // MARK: - Memory per profile and kind

    @Test("Nothing remembered reads as no choice — old states stay readable")
    func emptyMemory() {
        let memory = LibraryChoiceMemory(store: InMemoryStore(), profile: "anna")
        #expect(memory.remembered(.homeVideos) == nil)
    }

    @Test("A choice comes back for the same profile and kind")
    func remembersChoice() {
        let memory = LibraryChoiceMemory(store: InMemoryStore(), profile: "anna")
        memory.remember("h2", for: .homeVideos)
        #expect(memory.remembered(.homeVideos) == "h2")
    }

    @Test("Each profile keeps its own choice")
    func perProfile() {
        let store = InMemoryStore()
        LibraryChoiceMemory(store: store, profile: "anna").remember("h2", for: .homeVideos)
        LibraryChoiceMemory(store: store, profile: "ben").remember("f1", for: .homeVideos)
        #expect(LibraryChoiceMemory(store: store, profile: "anna").remembered(.homeVideos) == "h2")
        #expect(LibraryChoiceMemory(store: store, profile: "ben").remembered(.homeVideos) == "f1")
        #expect(LibraryChoiceMemory(store: store, profile: "carla").remembered(.homeVideos) == nil)
    }

    @Test("Each kind keeps its own choice")
    func perKind() {
        let memory = LibraryChoiceMemory(store: InMemoryStore(), profile: "anna")
        memory.remember("k1", for: .movies)
        #expect(memory.remembered(.movies) == "k1")
        #expect(memory.remembered(.homeVideos) == nil)
    }

    /// The key is new and additive: basis, kind, profile — the profile at the end like
    /// ``Core/ProfileStore/bucket(_:forItem:)``.
    @Test("The key carries kind and profile")
    func keyShape() {
        #expect(
            LibraryChoiceMemory(store: InMemoryStore(), profile: "anna").key(for: .homeVideos)
                == "libraryChoice.homeVideos.anna")
        #expect(
            LibraryChoiceMemory(store: InMemoryStore(), profile: nil).key(for: .movies)
                == "libraryChoice.movies")
    }

    // MARK: - Tab and Home

    @Test("Each library kind with a tab maps to it")
    func sectionForKind() {
        #expect(MediaTabBar.Section(libraryKind: .series) == .series)
        #expect(MediaTabBar.Section(libraryKind: .movies) == .movies)
        #expect(MediaTabBar.Section(libraryKind: .homeVideos) == .homeVideos)
        #expect(MediaTabBar.Section(libraryKind: .mixed) == nil)
        #expect(MediaTabBar.Section(libraryKind: .portalLevel) == nil)
    }

    private static func shelf(_ id: String) -> HomeModel.Shelf {
        HomeModel.Shelf(id: id, titleKey: id, items: [], usesWideCards: false)
    }

    /// "All" on a shelf leads into the tab with exactly this library.
    @Test("A library shelf with siblings of its kind gets an All card")
    func allCardWithSiblings() {
        #expect(HomeView.allTarget(for: Self.shelf("h2"), in: Self.server) == Self.holiday)
        #expect(HomeView.allTarget(for: Self.shelf("k1"), in: Self.server) == Self.kids)
    }

    /// **Home stays as it was with a single library** — the tab shows it anyway.
    @Test("A shelf of the only library of its kind gets no All card")
    func noAllCardWhenAlone() {
        #expect(HomeView.allTarget(for: Self.shelf("s1"), in: Self.server) == nil)
    }

    @Test("Shelves that are no library get no All card")
    func noAllCardForOtherShelves() {
        let mixed = Core.Library(id: "c1", name: "Collections", kind: .mixed)
        let other = Core.Library(id: "c2", name: "Boxes", kind: .mixed)
        #expect(HomeView.allTarget(for: Self.shelf("recent"), in: Self.server) == nil)
        #expect(HomeView.allTarget(for: Self.shelf("c1"), in: [mixed, other]) == nil)
    }
}
