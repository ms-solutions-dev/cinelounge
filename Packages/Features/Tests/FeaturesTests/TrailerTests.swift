import Core
import CoreGraphics
import DesignSystem
import Foundation
import Testing

@testable import Features

/// Checks the trailer without an engine, without a server and without a TV.
///
/// Two things go wrong here, and both only show up in the living room: A trailer
/// plays with the engine choice of the film and stays black, or it starts for every title
/// while browsing and makes the library unusable over a narrow
/// connection. Neither is visible from the UI — all you see
/// is that "something doesn't work".
@Suite("Trailer")
@MainActor
struct TrailerTests {

    // MARK: - Setup

    private func film(container: MediaSource.Container = .mp4) -> MediaItem {
        MediaItem(
            id: "film",
            kind: .movie,
            title: "Zirkel der Uhrmacher",
            source: MediaSource(container: container)
        )
    }

    /// The trailer as it sits on the test server: MKV with HEVC, HDR10, five audio tracks
    /// and three image-subtitle tracks — while the film itself is MP4.
    private func localTrailer(container: MediaSource.Container = .mkv) -> MediaItem {
        MediaItem(
            id: "trailer-1",
            kind: .movie,
            title: "Zirkel der Uhrmacher — Trailer",
            runtime: 138,
            source: MediaSource(
                container: container,
                videoCodec: "hevc",
                videoRange: .hdr10,
                audioTracks: (0..<5).map {
                    MediaTrack(id: "a\($0)", kind: .audio, title: "Ton \($0)")
                }
            )
        )
    }

    // MARK: - The target

    @Test("The engine choice follows the trailer's source, not the movie's")
    func engineFollowsTrailerSource() async {
        // The trailer is a separate file with its own container. Whoever adopts the
        // film's decision sends MKV **raw** to the
        // system player: the picture stays black, the sound plays, and nobody
        // looks for the cause in the file. Since 2026-08-10 it is repackaged
        // instead — but according to the trailer's own properties.
        let source = TrailerSourceDouble(trailer: localTrailer())

        let target = await TrailerPlayback.target(for: film(), from: source)

        // Since 2026-08-15. (VLC removal, stage 1) the answer for MKV is:
        // **server segmenting** — the trailer host cannot repackage,
        // and a remuxInApp decision would mean raw Matroska on the system player,
        // black and silent (on-device finding: "trailers do not play").
        #expect(
            target?.decision.delivery == .hls,
            "MKV belongs neither raw nor as a repack job on the trailer host")
        #expect(target?.itemID == "trailer-1", "the trailer is played, not the movie")
    }

    @Test("The target carries the trailer kind and therefore reports no progress")
    func trailerReportsNoProgress() async {
        // A trailer that ends up under "Continue Watching" as "40 % watched" is a
        // bug you only notice once it is there — and then it is there on
        // every device. The identifier is set: the kind decides, not
        // its absence.
        let source = TrailerSourceDouble(trailer: localTrailer())

        let target = await TrailerPlayback.target(for: film(), from: source)

        #expect(target?.kind == .trailer)
        #expect(target?.tracksProgress == false)
        #expect(target?.title == "Zirkel der Uhrmacher", "the movie is on screen, not the file")
        #expect(target?.duration == 138)
    }

    @Test("The bandwidth limit also applies to the trailer")
    func qualityLimitApplies() async {
        // Through the tunnel a measured 0.3 Mbit/s is available. A trailer that is
        // delivered unchanged buffers endlessly there — and because it starts by itself,
        // the whole view looks broken although it works correctly.
        let source = TrailerSourceDouble(trailer: localTrailer())

        let target = await TrailerPlayback.target(for: film(), from: source, quality: .minimal)

        // With a Jellyfin server the limit stays in the segmenting — the server
        // transcodes down within HLS, and the native engine plays.
        #expect(target?.decision.delivery == .hls)
        #expect(target?.decision.maxBitrate == StreamQuality.minimal.bitrate)
        #expect(target?.decision.isBandwidthLimited == true)
    }

    @Test("Without an attached trailer there is no target and so no button")
    func noTrailerNoTarget() async {
        // The normal case: most titles have no trailer. The button must then
        // not stand there dimmed — on tvOS even a dimmed button takes
        // focus, and then it sits on something that does not respond.
        let source = TrailerSourceDouble(trailer: nil)

        #expect(await TrailerPlayback.target(for: film(), from: source) == nil)
    }

    @Test("A trailer without technical details yields no target")
    func trailerWithoutSourceIsNoTarget() async {
        // Without a ``MediaSource`` the engine choice is blind. A guessed engine would be
        // worse than no button: it picks the wrong one in half the cases,
        // and the error looks like a server error.
        let bare = MediaItem(id: "trailer-1", kind: .movie, title: "Trailer")
        let source = TrailerSourceDouble(trailer: bare)

        #expect(await TrailerPlayback.target(for: film(), from: source) == nil)
    }

    // MARK: - Dwell time

    @Test("Before the dwell time elapses nothing starts and nothing is asked")
    func nothingBeforeDwell() async {
        // The actual purpose of the dwell time. Without it every step forward would trigger
        // a request and a half-started playback — with three hundred titles,
        // three hundred times.
        let source = TrailerSourceDouble(trailer: localTrailer())
        let autostart = TrailerAutostart(wait: { _ in await TrailerTests.never() })
        autostart.configure(
            preferences: TrailerPreferences(),
            load: { item in
                await TrailerPlayback.target(for: item, from: source)
            })

        autostart.focus(film())
        // A few iterations so that the task could actually start. Without that
        // the proof would only be that nothing has happened yet.
        for _ in 0..<5 { await Task.yield() }

        #expect(autostart.running == nil)
        #expect(source.asked.isEmpty, "no request goes out before the time")

        autostart.stop()
    }

    @Test("After the dwell time the focused title's trailer plays")
    func startsAfterDwell() async {
        // Otherwise the whole column would be poorer by one reaction that the user
        // explicitly wanted.
        let source = TrailerSourceDouble(trailer: localTrailer())
        let autostart = TrailerAutostart(wait: { _ in })
        autostart.configure(
            preferences: TrailerPreferences(),
            load: { item in
                await TrailerPlayback.target(for: item, from: source)
            })

        autostart.focus(film())
        await autostart.settle()

        #expect(autostart.running?.itemID == "film")
        #expect(autostart.running?.target.kind == .trailer)
        #expect(source.asked == ["film"])
    }

    @Test("A title change restarts the clock and queries only the last title")
    func focusChangeRestartsClock() async {
        // That is the browsing case: Whoever moves through a library with the remote
        // touches twenty titles in two seconds. If every
        // focus change asked, the dwell time would be pointless — and the last
        // answer would also land on a different poster.
        let source = TrailerSourceDouble(trailer: localTrailer())
        let autostart = TrailerAutostart(wait: { _ in })
        autostart.configure(
            preferences: TrailerPreferences(),
            load: { item in
                await TrailerPlayback.target(for: item, from: source)
            })

        autostart.focus(film())
        autostart.focus(MediaItem(id: "zweiter", kind: .movie, title: "Ein anderer Film"))
        await autostart.settle()

        #expect(source.asked == ["zweiter"], "the skipped title is not queried")
        #expect(autostart.running?.itemID == "zweiter")
    }

    @Test("With auto-start off it is not even queried")
    func disabledStartsNothing() async {
        // The switch is the only handle on the road. If it were asked anyway,
        // it would be ineffective and the cause would be visible nowhere — the request is in
        // no log the user reads.
        let source = TrailerSourceDouble(trailer: localTrailer())
        let autostart = TrailerAutostart(wait: { _ in })
        autostart.configure(
            preferences: TrailerPreferences(autostarts: false),
            load: { item in
                await TrailerPlayback.target(for: item, from: source)
            })

        autostart.focus(film())
        await autostart.settle()

        #expect(autostart.running == nil)
        #expect(source.asked.isEmpty)
    }

    @Test("Without a read setting nothing starts")
    func startsNothingBeforeConfigured() async {
        // The setting lives in the Keychain and only exists once the column
        // is up. A trailer that starts before that can no longer be prevented with the switch —
        // it has already made sound by then.
        let autostart = TrailerAutostart(wait: { _ in })

        autostart.focus(film())
        await autostart.settle()

        #expect(autostart.running == nil)
    }

    @Test("Leaving the view stops the trailer")
    func stopClearsRunning() async {
        // Sound coming from a view nobody sees any more is the
        // worst error in this area: You cannot find the source and quit
        // the app.
        let source = TrailerSourceDouble(trailer: localTrailer())
        let autostart = TrailerAutostart(wait: { _ in })
        autostart.configure(
            preferences: TrailerPreferences(),
            load: { item in
                await TrailerPlayback.target(for: item, from: source)
            })

        autostart.focus(film())
        await autostart.settle()
        #expect(autostart.running != nil)

        autostart.stop()

        #expect(autostart.running == nil)
    }

    // MARK: - Screen space

    @Test("The trailer stays within the information column")
    func trailerFitsColumn() {
        // SwiftUI centres content that is too wide and it overflows on both sides
        // without any warning. Here it would run over the grid on the left and under the
        // jump marks on the right — on the TV that looks like a margin error.
        #expect(TrailerSurface.size.width <= DetailColumn.width)

        // And it must not make the column taller than the poster, otherwise everything below it
        // slides up during the cross-fade while the eye is on the picture.
        #expect(TrailerSurface.size.height <= DetailColumn.posterSize.height)

        // Visibly larger than the poster, otherwise the change would not be an improvement
        // but just a disturbance.
        #expect(TrailerSurface.size.width > DetailColumn.posterSize.width)
    }

    // MARK: - Tooling

    /// A wait that never ends — to prove that nothing
    /// happens before it expires. Cleanup goes through ``TrailerAutostart/stop()``, which
    /// cancels the task.
    static func never() async {
        try? await Task.sleep(for: .seconds(3600))
    }
}

extension TrailerAutostart {

    /// Waits until the triggered task is done.
    ///
    /// Necessary because the autostart has two suspension points — the dwell time
    /// and the query. A single ``Task/yield()`` is not enough for that, and a
    /// wait in the test suite would be a race that fails by chance at some point.
    func settle() async {
        // Await the task itself, do not count iterations: The old
        // counter (20 × yield) only passed if enough else was running — alone
        // it reliably failed (noticed 2026-08-15, during the VLC removal).
        await pending?.value
    }
}

// MARK: - Duplicates

/// A source with at most one trailer that records what was asked for.
///
/// A dedicated double and not the playback one: What counts here is exactly **when** the
/// trailer is asked for, and that one does not record it.
@MainActor
final class TrailerSourceDouble: ContentSource {

    /// No background sync — test doubles report nothing afterwards.
    /// Written out because the contract no longer has a default for it; why
    /// is explained at ``ContentSource/listChanges()``.
    func listChanges() async -> AsyncStream<Void> { AsyncStream { $0.finish() } }

    nonisolated var displayName: String { "Doppel" }
    /// Like Jellyfin: The server can deliver from a given position.
    nonisolated var canStartAtOffset: Bool { true }
    /// **A test double keeps its own state** — nobody is supposed to wrap it.
    nonisolated var tracksStateItself: Bool { true }

    func setPlayed(_ isPlayed: Bool, for itemID: String) async throws {}
    func setFavorite(_ isFavorite: Bool, for itemID: String) async throws {}
    func favorites() async throws -> [MediaItem] { [] }

    private let trailerToReturn: MediaItem?
    private(set) var asked: [String] = []

    init(trailer: MediaItem?) {
        self.trailerToReturn = trailer
    }

    func trailer(for itemID: String) async throws -> MediaItem? {
        asked.append(itemID)
        return trailerToReturn
    }

    func streamURL(for itemID: String, decision: PlaybackDecision) async throws -> URL {
        URL(string: "https://server/Videos/\(itemID)/stream")!
    }

    func libraries() async throws -> [Core.Library] { [] }

    func items(in library: Core.Library.ID, filter: ItemFilter) async throws -> [MediaItem] { [] }

    func item(id: String) async throws -> MediaItem { film }

    func children(of itemID: String) async throws -> [MediaItem] { [] }

    func resumable(limit: Int) async throws -> [MediaItem] { [] }

    func segments(for itemID: String) async throws -> [MediaSegment] { [] }

    func report(progress: PlaybackProgress, for itemID: String, isPaused: Bool) async throws {}

    private let film = MediaItem(id: "film", kind: .movie, title: "Zirkel der Uhrmacher")
}
