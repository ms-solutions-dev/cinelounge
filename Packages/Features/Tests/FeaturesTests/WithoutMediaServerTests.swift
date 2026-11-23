import Core
import Foundation
import SourceProbe
import Testing

@testable import Features

/// **The shell without a media server** — AP29, 2026-09-11.
///
/// **There were two dead ends here.** ``RootView`` kept a separate signpost each for "channel list
/// only" and "portals only": one sentence, one "Add server" button, the
/// language choice. Whoever stood there reached **no setting** — those hang off the
/// sidebar, and that existed only with a media server. On tvOS a screen the
/// remote cannot lead out of.
struct WithoutMediaServerTests {

    /// **The start follows what is set up — and the order stands elsewhere.**
    ///
    /// ``Core/AccountState/landing`` decides which area it is;
    /// ``MainView/start(forItem:)`` merely translates it into a row of the sidebar. Two
    /// places for the same order drifted apart at the first new path.
    @MainActor
    @Test("Every section has its start in the sidebar")
    func start() {
        #expect(MainView.start(forItem: .media) == .media)
        #expect(MainView.start(forItem: .live) == .live)
        #expect(MainView.start(forItem: .portals) == .portals)
        // **`.setup` does not arrive here** — whoever is there sees the setup and
        // not the shell. The case is handled anyway: an enum whose
        // translation left a case open would fall over at the next new area.
        #expect(MainView.start(forItem: .setup) == .media)
    }

    /// **Whoever has a channel list lands in the Live area and not on an empty
    /// media library.**
    ///
    /// The order is that of ``Core/AccountState/landing``: media library, Live,
    /// portals — the only one that does not change when a path is added.
    @MainActor
    @Test("Without a media server the shell starts where something is")
    func startFromState() {
        let channelsOnly = AccountState(hasJellyfin: false, hasPlaylist: true, hasPortals: false)
        #expect(MainView.start(forItem: channelsOnly.landing) == .live)

        let portalsOnly = AccountState(hasJellyfin: false, hasPlaylist: false, hasPortals: true)
        #expect(MainView.start(forItem: portalsOnly.landing) == .portals)

        let fullAccount = AccountState(hasJellyfin: true, hasPlaylist: true, hasPortals: true)
        #expect(MainView.start(forItem: fullAccount.landing) == .media)
    }

    /// **The Sammelquelle works without a media server** — it is the reason why the
    /// shell does.
    @Test("Without a media server the remaining origins answer")
    func aggregateSourceWithoutMediaServer() async throws {
        let aggregateSource = AggregateSource(jellyfin: nil, provider: nil, portals: nil)
        #expect(try await aggregateSource.libraries().isEmpty)
        #expect(try await aggregateSource.resumable(limit: 12).isEmpty)
        #expect(try await aggregateSource.collections().isEmpty)
    }

    /// **And the "Media library" row drops out instead of standing there empty.**
    ///
    /// All four areas behind it come from the media server. Without it there would be a
    /// row with four empty pages, and that looks like a bug, not like
    /// a missing setup. ``Core/AccountState/showsMediaBar`` answers
    /// the same question — it was built and had, until today, **no reader**.
    @Test("The library row depends on the media server")
    func libraryRow() {
        #expect(AccountState(hasJellyfin: true, hasPlaylist: false, hasPortals: false).showsMediaBar)
        #expect(
            !AccountState(hasJellyfin: false, hasPlaylist: true, hasPortals: true).showsMediaBar)
    }

    /// **The two dead ends are gone — and their language keys with them.**
    ///
    /// A key without a reader is no harm, but it is a claim: it says
    /// that this screen exists. This is checked against the source text, because a deleted
    /// screen could otherwise only be recognized by the fact that one no longer finds it.
    @Test("No signpost any more that points only at itself")
    func noDeadEnds() throws {
        let rootText = try SourceText.read("RootView.swift", in: .tvApp)

        #expect(!rootText.contains("liveHome"))
        #expect(!rootText.contains("portalHome"))
        // And the shell stands for every area — since AP88 wave 5 without a switch at all:
        // the setup is a journey of its own, and RootView builds one MainView.
        #expect(rootText.components(separatedBy: "MainView(").count == 2)
        #expect(!rootText.contains("switch area"))
    }
}
