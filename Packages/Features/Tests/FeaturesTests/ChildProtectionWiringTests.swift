import Core
import Foundation
import ParentalControls
import ProfileKit
import SourceProbe
import Testing

@testable import Features

/// **Picture-in-picture, favorites and Top Shelf behind the filter** (check 2026-09-25,
/// findings 1–4).
///
/// The return calculation is tested at
/// ``ParentalControls/ChildScope/returnTarget(_:title:origin:channels:isVisible:)``. The
/// shell and the settings are views that `swift test` does not build; what is stated here is
/// therefore that they **use** the calculation and the filter — otherwise they would remain
/// tested functions without a caller.
@MainActor
@Suite("Child protection: return, favorites, shelf")
struct ChildProtectionWiringTests {

    private func state(kind: Profile.Kind) -> ParentalControlsState {
        let store = InMemoryStore()
        let profileStore = InMemoryStore()
        var person = Profile(name: kind == .kind ? "Selin" : "Max")
        person.kind = kind
        var ledger = ProfileBook()
        ledger.create(person)
        ledger.write(in: profileStore)
        if kind == .kind { _ = Pin(store: store).set("1234") }
        let state = ParentalControlsState(
            store: store,
            childAccounts: ChildAccountList(store: InMemoryStore()),
            profileStore: profileStore,
            childMode: ChildMode(store: UserDefaults(suiteName: UUID().uuidString)!))
        if kind == .kind { state.set(limit: .from6, forItem: person.identifier.rawValue) }
        return state
    }

    private static func target(_ kind: PlaybackTarget.Kind, id: String? = "abend") -> PlaybackTarget {
        PlaybackTarget(
            itemID: id, title: "Ziel", url: URL(string: "https://server/ziel.m3u8")!,
            decision: PlaybackDecision(
                engine: .native, delivery: .hls, reason: .containerNotNativelySupported),
            kind: kind)
    }

    private static let evening = MediaItem(
        id: "0a1b2c3d4e5f60718293a4b5c6d7e8f9", kind: .movie, title: "Abend", ageRating: "18")
    private static let dragon = MediaItem(
        id: "1b2c3d4e5f60718293a4b5c6d7e8f90a", kind: .movie, title: "Drache", ageRating: "0")

    @Test("Finding 2: An 18+ title does not come back from Picture in Picture for the child")
    func returnFiltered() {
        let kind = state(kind: .kind)
        let calculation = { (title: MediaItem?, target: PlaybackTarget) in
            kind.rule.scope.returnTarget(
                target, title: title, channels: [], isVisible: LivePreferences())
        }
        #expect(!calculation(Self.evening, Self.target(.recording)))
        #expect(calculation(Self.dragon, Self.target(.recording)))
        #expect(!calculation(nil, Self.target(.recording)))
        #expect(!calculation(nil, Self.target(.live)))
    }

    @Test("Finding 2: For the adult nothing changes about the return")
    func returnAdult() {
        let large = state(kind: .adult)
        let calculation = { (title: MediaItem?, target: PlaybackTarget) in
            large.rule.scope.returnTarget(
                target, title: title, channels: [], isVisible: LivePreferences())
        }
        #expect(calculation(Self.evening, Self.target(.recording)))
        #expect(calculation(nil, Self.target(.recording)))
        #expect(calculation(nil, Self.target(.live)))
    }

    private func sourceText(_ name: String) throws -> String {
        try SourceText.read(name, in: .features)
    }

    @Test("Finding 1: Every player setup gets the filter")
    func playerGetsFilter() throws {
        let wrapper = try sourceText("Shell/MainView.swift")
        #expect(wrapper.contains("mayPlay: mayPlay\n"))
        #expect(wrapper.contains("lock.rule.scope.opens($0)"))
        let detail = try sourceText("Detail/DetailView.swift")
        #expect(detail.contains("mayPlay: model.mayPlay"))
        #expect(detail.contains("quality: quality, mayPlay: mayPlay)"))
    }

    @Test(
        "Finding 2: Switching discards Picture in Picture and the channel catalog, the return goes through the filter"
    )
    func pictureInPictureDiscarded() throws {
        let wrapper = try sourceText("Shell/MainView.swift")
        #expect(wrapper.components(separatedBy: "discardRunning()").count - 1 == 3)
        #expect(wrapper.contains("lock.load()\n                discardRunning()"))
        #expect(wrapper.contains("media = .home\n                    discardRunning()"))
        #expect(wrapper.contains("PictureInPictureKeeper.shared.discard()\n        liveChannels = []"))
        #expect(wrapper.contains("Task { await restore(request) }"))
        #expect(!wrapper.contains("playing = request"))
        #expect(wrapper.contains("rule.scope.returnTarget("))
    }

    @Test("Finding 3: All three title kinds of the favorites go through the filter")
    func favoritesFiltered() throws {
        let wrapper = try sourceText("Shell/MainView.swift")
        let area = try #require(wrapper.components(separatedBy: "private var favoritesArea").last)
        let bodyContent = try #require(area.components(separatedBy: "onOpen:").first)
        let filter = ".filter { rule.scope.opens($0) }"
        #expect(bodyContent.components(separatedBy: filter).count - 1 == 3)
    }

    @Test("Finding 4: Settings and background rewrite the shelf")
    func shelfCaughtUp() throws {
        #expect(
            try sourceText("Settings/SettingsView.swift").contains(
                ".modifier(ShelfCatchUp(lock: childLock))"))
        #expect(
            try sourceText("Settings/ProfileSettings.swift").contains(
                ".modifier(ShelfCatchUp(lock: lock, profile: profile))"))
        #expect(
            try sourceText("Shell/HomeShelf.swift").contains(
                "if fresh == .background { HomeShelf.writeFromSession() }"))
    }
}
