import Core
import Flows
import Foundation
import ParentalControls
import ProfileKit
import Testing

@testable import Features

/// **The circumventions of the child interface — closed** (counter-check AP45, 2026-09-25).
///
/// The reconstruction U1–U4 of the counter-check proved every gap with a green `#expect` on
/// the wrong thing. Here are the same setups with the reverse expectation, and every check
/// goes through the model or the calculation that decides in the app: ``ShellModels`` for the
/// remembered models, ``ParentalControls/ChildScope/opens(_:origin:)`` for the
/// shell's funnel, ``DetailModel`` for the detail page's lists and ``ChildGuard`` for what a
/// switch discards.
@MainActor
@Suite("Circumventions of the child interface — closed")
struct ChildCircumventionTests {

    // MARK: - Setup

    private func state(
        kind: Profile.Kind, pin: Bool = false, limit: AgeLimit? = nil
    ) -> ParentalControlsState {
        let store = InMemoryStore()
        if pin { _ = Pin(store: store).set("1234") }
        let profileStore = InMemoryStore()
        var person = Profile(name: kind == .kind ? "Selin" : "Max")
        person.kind = kind
        var ledger = ProfileBook()
        ledger.create(person)
        ledger.write(in: profileStore)
        let state = ParentalControlsState(
            store: store,
            childAccounts: ChildAccountList(store: InMemoryStore()),
            profileStore: profileStore,
            childMode: ChildMode(store: UserDefaults(suiteName: UUID().uuidString)!))
        if let limit { state.set(limit: limit, forItem: person.identifier.rawValue) }
        return state
    }

    nonisolated private static let dragon = MediaItem(
        id: "drache", kind: .movie, title: "Der kleine Funkelfuchs", ageRating: "0")
    nonisolated private static let evening = MediaItem(
        id: "abend", kind: .movie, title: "Ein später Abend", ageRating: "16")

    /// A source that delivers a cleared title and a 16-rated title for everything.
    final class Source: ContentSource, @unchecked Sendable {
        nonisolated var displayName: String { "Doppel" }
        nonisolated var canStartAtOffset: Bool { false }
        nonisolated var tracksStateItself: Bool { true }
        nonisolated func imageURL(
            itemID: String, kind: ImageKind, width: Int, tag: String?
        )
            -> URL?
        { nil }
        func libraries() async throws -> [Core.Library] {
            [Core.Library(id: "jf-filme", name: "Filme", kind: .movies)]
        }
        func items(in library: Core.Library.ID, filter: ItemFilter) async throws -> [MediaItem] {
            [ChildCircumventionTests.dragon, ChildCircumventionTests.evening]
        }
        func item(id: String) async throws -> MediaItem {
            if id == "serie" { return MediaItem(id: "serie", kind: .series, title: "Serie") }
            return ChildCircumventionTests.dragon
        }
        func children(of itemID: String) async throws -> [MediaItem] {
            [
                MediaItem(id: "f1", kind: .episode, title: "Folge 1", ageRating: "0"),
                MediaItem(id: "f2", kind: .episode, title: "Folge 2", ageRating: "16"),
            ]
        }
        func similarItems(to itemID: String, limit: Int) async throws -> [MediaItem] {
            [ChildCircumventionTests.dragon, ChildCircumventionTests.evening]
        }
        func resumable(limit: Int) async throws -> [MediaItem] { [] }
        func segments(for itemID: String) async throws -> [MediaSegment] { [] }
        func streamURL(for itemID: String, decision: PlaybackDecision) async throws -> URL {
            throw Missing.nothing
        }
        func report(progress: PlaybackProgress, for itemID: String, isPaused: Bool) async throws {}
        func setPlayed(_ isPlayed: Bool, for itemID: String) async throws {}
        func setFavorite(_ isFavorite: Bool, for itemID: String) async throws {}
        func favorites() async throws -> [MediaItem] { [] }
        func listChanges() async -> AsyncStream<Void> { AsyncStream { $0.finish() } }
        enum Missing: Error { case nothing }
    }

    // MARK: - B2 (U1): Home carries the rule

    @Test("B2: Switching child→child with a different limit builds a new Home")
    func childToChildRebuilds() {
        let models = ShellModels()
        let a = state(kind: .kind, pin: true, limit: .from16)
        let b = state(kind: .kind, pin: true, limit: .from6)
        #expect(a.surface == b.surface)

        let previous = models.home(
            source: nil, provider: nil, portals: nil, channels: nil, anime: nil,
            rule: a.rule, surface: a.surface)
        let after = models.home(
            source: nil, provider: nil, portals: nil, channels: nil, anime: nil,
            rule: b.rule, surface: b.surface)
        #expect(previous !== after)
        // And the same rule still delivers the remembered model — otherwise every drawing would
        // rebuild.
        let again = models.home(
            source: nil, provider: nil, portals: nil, channels: nil, anime: nil,
            rule: b.rule, surface: b.surface)
        #expect(after === again)
    }

    // MARK: - B1 (U2): The library carries the rule

    @Test("B1: The child gets its own library model without the 16+ title")
    func libraryRebuildsForChild() async {
        let models = ShellModels()
        let source = Source()
        let library = Core.Library(id: "jf-filme", name: "Filme", kind: .movies)
        let adult = state(kind: .adult)
        let kind = state(kind: .kind, pin: true, limit: .from6)

        let previous = models.library(
            library, source: source, anime: nil, omdb: nil, rule: adult.rule)
        let after = models.library(
            library, source: source, anime: nil, omdb: nil, rule: kind.rule)
        #expect(previous !== after)

        await after.load()
        guard case .ready(let title) = after.state else {
            Issue.record("not ready: \(after.state)")
            return
        }
        #expect(title.map(\.id) == ["drache"])
    }

    // MARK: - B3 (U3): The funnel asks origin and scope

    @Test("B3: Portal and channel titles without approval do not open for the child")
    func funnelHoldsBackPortalTitles() {
        let kind = state(kind: .kind, pin: true, limit: .from6)
        let portal = MediaItem(id: "animehub|s1|/serie/1", kind: .series, title: "Portal")
        let channels = MediaItem(id: "sender-1", kind: .channel, title: "Sender")
        #expect(Origin.forItem(identifier: portal.id) == .portals)

        #expect(!kind.rule.scope.opens(portal))
        #expect(!kind.rule.scope.opens(channels))
        #expect(!kind.rule.scope.opens(Self.evening))
        #expect(kind.rule.scope.opens(Self.dragon))

        // The adult opens everything — the filter is not a lock for everyone.
        let adult = state(kind: .adult)
        #expect(adult.rule.scope.opens(portal))
        #expect(adult.rule.scope.opens(channels))
    }

    @Test("B3/M4: A channel plays only with scope and the adult-channel switch")
    func channelAsksScopeAndSwitch() throws {
        let url = try #require(URL(string: "http://sender.example/1"))
        let normal = Channel(id: "1", name: "Eins", streamURL: url, playlistID: "l")
        let adult = Channel(
            id: "2", name: "Nacht", streamURL: url, playlistID: "l", isAdult: true)
        let from = LivePreferences(showsAdultChannels: false)
        let on = LivePreferences(showsAdultChannels: true)
        let large = state(kind: .adult)
        let kind = state(kind: .kind, pin: true, limit: .from6)

        #expect(large.rule.scope.isPlaying(normal, isVisible: from))
        #expect(!large.rule.scope.isPlaying(adult, isVisible: from))
        #expect(large.rule.scope.isPlaying(adult, isVisible: on))
        #expect(!kind.rule.scope.isPlaying(normal, isVisible: on))
    }

    // MARK: - B4: A switch discards the open paths

    @Test("B4: A different limit on the same profile discards path and views")
    func switchDiscardsPath() {
        let identifier = Profile(name: "Selin").identifier
        let from16 = state(kind: .kind, pin: true, limit: .from16)
        let from6 = state(kind: .kind, pin: true, limit: .from6)
        let old = ChildGuard.RuleState(active: identifier, surface: .kind, rule: from16.rule)
        let fresh = ChildGuard.RuleState(active: identifier, surface: .kind, rule: from6.rule)

        #expect(ChildGuard.discardsDestination(from: old, zu: fresh))
        #expect(!ChildGuard.discardsDestination(from: old, zu: old))
        // And a profile switch under the same rule likewise.
        let other = ChildGuard.RuleState(
            active: Profile(name: "Max").identifier, surface: .kind, rule: from16.rule)
        #expect(ChildGuard.discardsDestination(from: old, zu: other))
    }

    // MARK: - M3: The lists of the detail page

    @Test("M3: \"Similar titles\" show the child no 16+ title")
    func similarAreFiltered() async {
        let kind = state(kind: .kind, pin: true, limit: .from6)
        let model = DetailModel(
            source: Source(), item: Self.dragon, rule: kind.rule,
            surface: kind.surface)
        await model.load()
        #expect(model.similar.map(\.id) == ["drache"])
    }

    @Test("M3: The episodes of a series are filtered")
    func episodesAreFiltered() async {
        let kind = state(kind: .kind, pin: true, limit: .from6)
        let model = DetailModel(
            source: Source(), item: MediaItem(id: "serie", kind: .series, title: "Serie"),
            rule: kind.rule, surface: kind.surface)
        await model.load()
        #expect(model.episodes.map(\.id) == ["f1"])
    }

    // MARK: - K1: No detour through the settings

    @Test("K1: A state button does not lead a child into the settings")
    func stateButtonLeadsChildNowhere() {
        let kind = ProtectionRule(deviceLocked: false, accountKind: .kind, isPinSet: false)
        for target in ActionTarget.allCases {
            #expect(ChildGuard.settingsArea(forItem: target, rule: kind) == nil)
        }
        #expect(ChildGuard.settingsArea(forItem: .accounts, rule: .pending) == .account)
        #expect(
            ChildGuard.settingsArea(forItem: .channelLists, rule: .pending)
                == .playlists)
    }

    // MARK: - M2 (U4): A child without a PIN

    /// **U4 remains a finding** — without a PIN the rule does not apply, and that is intended
    /// (``ParentalControls/ProtectionRule``). What gets closed is the silent side: The profile
    /// sheet says so as soon as a limit is chosen for a child.
    @Test("M2: The profile sheet asks for a PIN when a child gets a limit without one")
    func childWithoutPinIsWarned() {
        let kind = state(kind: .kind, limit: .from6)
        #expect(!kind.rule.applies)
        #expect(ProfileSheet.promptsForPin(kind: .kind, isPinSet: kind.rule.isPinSet))
        #expect(!ProfileSheet.promptsForPin(kind: .kind, isPinSet: true))
        #expect(!ProfileSheet.promptsForPin(kind: .adult, isPinSet: false))
    }
}
