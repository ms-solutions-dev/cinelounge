import Core
import DesignSystem
import Foundation
import Playback
import RatingsKit
import SwiftUI
import Trailer

#if canImport(UIKit)
    import UIKit
#endif

/// The trailer in the poster's place.
///
/// **Its own host and therefore its own engine.** The trailer runs next to the library
/// and not in the playback view; a shared host would mean that opening
/// a film inherits the running trailer — both audio tracks would play on top of each other,
/// exactly the case from the evidence in E0.
struct TrailerSurface: View {

    let target: PlaybackTarget

    /// The space the trailer occupies — 16:9, wide enough that next to the
    /// poster it reads as a picture and not as a postage stamp.
    ///
    /// Stays within ``DetailColumn/width``. Content that is too wide is centred by
    /// SwiftUI and overflows on **both** sides, without a warning; here
    /// it would run under the jump markers on the right edge. Recalculated in
    /// `TrailerTests`.
    static let size = CGSize(width: 460, height: 259)

    @State private var host = EngineHost()

    var body: some View {
        VideoSurface(host: host)
            .frame(width: Self.size.width, height: Self.size.height)
            // systemfarbe: Black behind it, because the picture sits within the frame and is not filled:
            // A trailer in 2.39:1 has bars at the top and bottom, and those should be
            // black and not let the app's base surface show through.
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            // The column sits as a sibling **next to** the grid, so focus moves
            // into it geometrically. A surface that accepts hits pulls focus out of
            // the grid, and with the remote there would be no way back.
            .allowsHitTesting(false)
            .onAppear { host.start(target) }
            // If the target changes without the view being recreated, the
            // previous trailer would otherwise keep running — nothing would be visible, everything audible.
            .onChange(of: target.id) { _, _ in host.start(target) }
            .onDisappear {
                // There is no `deinit` that could do this: Swift 6 refuses access to the
                // engine there. Without this line the audio keeps playing
                // after the library has been left — the worst bug in
                // this area, because nobody can find the source of the sound.
                host.stop()
            }
    }
}

/// Builds the playback target for a title's trailer.
///
/// Stands on its own and in neither of the two models, because both need it: the
/// detail page for the button, the information column for the auto-start. Built
/// twice, the engine choice would have to be justified twice — and would be wrong once.
/// What was found as a trailer for a title: the choice according to the ``Core/TrailerRule``
/// and, if it is the own file, its title — the engine choice hangs on that.
struct TrailerFinding: Equatable, Sendable {
    let choice: TrailerChoice
    let file: MediaItem?
}

enum TrailerError: Error {
    /// The own file is present, but the server gives no address or nothing
    /// technical about it.
    case fileWithoutAddress
}

nonisolated enum TrailerPlayback {

    /// Looks for the trailer: own file in the catalog **and** TMDb videos, decided by
    /// the language rule (AP78). Without TMDb access it stays with the file as before.
    ///
    /// Costs one request to the server (the file) and the TMDb lookup that the
    /// detail page fetches anyway (cached for 14 days). **Not** the YouTube resolution: that
    /// only comes in ``target(forItem:film:from:quality:)``, because it takes seconds and is only
    /// needed when someone presses or the info column starts up.
    static func fund(
        for film: MediaItem, from source: any ContentSource, tmdb: TMDbClient?
    ) async -> TrailerFinding? {
        let file = (try? await source.trailer(for: film.id)) ?? nil
        let info = file.map { TrailerFile(language: $0.source?.audioTracks.first?.language) }
        let choice = await TrailerSource.trailer(
            tmdb: film.ratings.tmdbID, search: DetailModel.titleSearch(forItem: film), file: info,
            appLanguage: AppLanguageSetting.current ?? "de", client: tmdb)
        guard let choice else { return nil }
        if case .file = choice { return TrailerFinding(choice: choice, file: file) }
        return TrailerFinding(choice: choice, file: nil)
    }

    /// The playback target for the find — for the file via the server, for YouTube via
    /// ``Trailer/TrailerResolution`` on the device.
    static func target(
        forItem fund: TrailerFinding, film: MediaItem, from source: any ContentSource,
        quality: StreamQuality
    ) async throws -> PlaybackTarget {
        switch fund.choice {
        case .file:
            guard let file = fund.file,
                let target = await fileTarget(file, film: film, from: source, quality: quality)
            else { throw TrailerError.fileWithoutAddress }
            return target
        case .youtube(let id, _):
            return try await youtubeTarget(id, title: film.title)
        }
    }

    /// YouTube as a target: HLS like a channel, the file like a direct play — both the
    /// system engine, without a repackager. `itemID` empty, ``PlaybackTarget/Kind/trailer``: no
    /// position, no Continue Watching, no "watched".
    static func youtubeTarget(_ id: String, title: String) async throws -> PlaybackTarget {
        let address = try await TrailerResolution.address(youtubeID: id)
        return PlaybackTarget(
            itemID: nil,
            title: title,
            url: address.url,
            decision: PlaybackDecision(
                engine: .native,
                delivery: address.route == .hls ? .hls : .directPlay,
                reason: .nativeContainer,
                maxBitrate: nil,
                maxWidth: nil
            ),
            kind: .trailer
        )
    }

    /// Find and target in one step — for the info column's auto-start, which only asks
    /// after the dwell time and then needs everything at once.
    ///
    /// - Returns: `nil` if no trailer is attached, the server knows nothing technical about it,
    ///   or YouTube does not resolve. The UI then shows no button and
    ///   starts nothing: a button that leads nowhere is worse than none,
    ///   because focus sits on it and nothing happens.
    static func target(
        for film: MediaItem,
        from source: any ContentSource,
        quality: StreamQuality = .unlimited,
        tmdb: TMDbClient? = nil
    ) async -> PlaybackTarget? {
        guard let fund = await fund(for: film, from: source, tmdb: tmdb) else { return nil }
        return try? await target(forItem: fund, film: film, from: source, quality: quality)
    }

    /// The own file as a target — the only way there was before AP78.
    private static func fileTarget(
        _ trailer: MediaItem, film: MediaItem, from source: any ContentSource,
        quality: StreamQuality
    ) async -> PlaybackTarget? {
        // **The trailer's source, not the film's.** It is a file of its own
        // with its own container: the trailer in the catalog is MKV with HEVC, while the
        // film itself is MP4. With the film's source the choice would fall on
        // the system player, and the picture would stay black while the audio plays.
        guard let media = trailer.source else { return nil }

        // Without a subtitle preference: nobody picks a track for a trailer, and
        // a preference that is set would fix the choice unnecessarily.
        var decision = PlaybackEngineSelector.decide(
            for: media, quality: quality, hasMediaServer: true,
            // **Without this argument the trailer loses its colours**
            // (check agent 2026-08-23): if it is missing, the default `false` applies, and
            // `hevc-rangetype` thereby drops out of the address. The server then copies
            // Dolby Vision profile 5 as `hvc1`, and the IPT colour space is rendered
            // raw — purple faces, poison-green sky. Exactly the
            // finding that has been open in the roadmap since the on-device test.
            displaySupportsHDR: await MainActor.run { DisplaySupport.hdr },
            canDecodeHEVC: DeviceCodecs.hasHEVC)

        // **The trailer host cannot repackage** — the repackager lives in
        // playback (``PlayerModel``), not in this small surface. A
        // remuxInApp decision would mean here: the native engine gets the raw
        // Matroska and stays black — exactly the on-device finding of 2026-08-15.
        // ("trailers do not play in the preview"; before AP1 VLC caught this
        // silently). Instead the server stitches: the same native engine,
        // only with fMP4 segments from the server instead of from its own repackager.
        if decision.delivery == .remuxInApp {
            decision = PlaybackDecision(
                engine: .native,
                delivery: .hls,
                reason: decision.reason,
                maxBitrate: decision.maxBitrate,
                maxWidth: decision.maxWidth,
                isBandwidthLimited: decision.isBandwidthLimited
            )
        }

        guard let url = try? await source.streamURL(for: trailer.id, decision: decision) else {
            return nil
        }

        return PlaybackTarget(
            itemID: trailer.id,
            title: film.title,
            // The second line comes from the server. A "Trailer" assembled here
            // would be looked up in the device language, while the UI follows the
            // app's language choice — the display would be half translated. The same
            // consideration is at ``PlayerModel/episodeSubtitle(for:)``.
            subtitle: trailer.title == film.title ? nil : trailer.title,
            url: url,
            decision: decision,
            duration: trailer.runtime,
            // More hangs on the kind than a label: ``tracksProgress`` is
            // thereby false, and the trailer does not end up as "40 % watched" under
            // "Continue Watching".
            kind: .trailer
        )
    }
}

/// The clock that triggers the auto-start.
///
/// **Why an object of its own and not a timer in the view.** That is exactly what
/// the switching in the Home screen's head area already failed on once: the clock
/// hung on the view, which was replaced on switching, and therefore ran exactly
/// once. ``DetailColumn`` replaces its content on every focus change via
/// `.id(item.id)` — a clock in it would be a new one with every move on and would never
/// expire. This object hangs on the column's outer frame, and that
/// stays put across all focus changes.
///
/// Setting, query and wait time come from outside, because the sequence is the only
/// part of the trailer that can be tested without a TV.
final class TrailerAutostart: ObservableObject {

    /// The trailer that should run.
    ///
    /// The ID of the **film** is included and not only that of the trailer: the
    /// column draws it only if it belongs to the title in focus. Without this
    /// comparison, after a focus change the previous title's trailer would
    /// briefly appear next to the new poster.
    struct Running: Equatable {
        let itemID: String
        let target: PlaybackTarget
    }

    @Published private(set) var running: Running?

    /// Nothing starts until ``configure(preferences:load:)`` has read.
    ///
    /// The default in the store is **on**; here it is **off** nonetheless, because audio
    /// that kicks in before the setting is read can no longer
    /// be prevented with the switch.
    private var preferences = TrailerPreferences(autostarts: false)

    private var load: @MainActor (MediaItem) async -> PlaybackTarget?

    /// The wait time as a dependency: a test that sleeps for three seconds is
    /// switched off at its first random failure and checks nothing afterwards.
    private let wait: @MainActor (TimeInterval) async -> Void

    /// Readable for the tests, so that they can **wait for** the startup
    /// instead of counting passes of the event loop — a counter failed
    /// solo and passed in the full run, depending on how much else was running.
    private(set) var pending: Task<Void, Never>?

    init(
        load: @escaping @MainActor (MediaItem) async -> PlaybackTarget? = { _ in nil },
        wait: @escaping @MainActor (TimeInterval) async -> Void = TrailerAutostart.sleep
    ) {
        self.load = load
        self.wait = wait
    }

    static func sleep(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    // No `deinit`. Teardown lives in ``stop()`` and is called when the
    // view disappears — the reasoning as a whole is at ``NativePlaybackEngine``.

    /// Takes over setting and query as soon as the column stands.
    ///
    /// Not in the initialiser: the column is rebuilt on every image change of the grid,
    /// the setting lives in the Keychain, and an access to it on every
    /// image change would be noticeable on the main thread.
    func configure(
        preferences: TrailerPreferences,
        load: @escaping @MainActor (MediaItem) async -> PlaybackTarget?
    ) {
        self.preferences = preferences
        self.load = load
    }

    /// A different title is in focus — the clock starts over.
    func focus(_ item: MediaItem?) {
        guard let item else {
            stop()
            return
        }
        focus(id: item.id) { [load] in await load(item) }
    }

    /// The same for something that is not a title of the catalog — the short profile of a third-party
    /// film on the cast sheet (AP78). The ID only has to assign the find to the picture.
    func focus(id: String, load: @escaping @MainActor () async -> PlaybackTarget?) {
        // Cancel and clear first: the running trailer belongs to the previous title
        // and has to go before anything else happens.
        stop()

        guard preferences.autostarts else { return }

        pending = Task { [weak self] in
            guard let self else { return }
            await self.wait(self.preferences.dwell)

            // Cancelled means: focus has moved on. The query must then
            // no longer go out — otherwise the flood of requests would arise while paging through
            // that the dwell time is meant to prevent.
            guard !Task.isCancelled else { return }

            let target = await load()

            guard !Task.isCancelled, let target else { return }
            self.running = Running(itemID: id, target: target)
        }
    }

    /// Stops and cleans up. Must be called when the view is left, otherwise
    /// the audio keeps playing in a view nobody sees any more.
    func stop() {
        pending?.cancel()
        pending = nil
        running = nil
    }
}

extension TrailerPlayback {

    /// Whether the YouTube app is present — `canOpenURL` answers only for the scheme `youtube`
    /// registered in Info.plist.
    @MainActor static func canOpen(_ url: URL) -> Bool {
        #if canImport(UIKit)
            return UIApplication.shared.canOpenURL(url)
        #else
            return false
        #endif
    }

    @MainActor static func open(_ url: URL) {
        #if canImport(UIKit)
            UIApplication.shared.open(url)
        #endif
    }
}

/// The language badge on the trailer button (AP78): "DE", "EN", "TR" — what the language rule
/// found. Small and muted, so that it is information and not a second button.
struct LanguageBadge: View {
    let text: String
    /// On the light, focused button the colour turns along with it.
    let bright: Bool

    init(_ text: String, bright: Bool) {
        self.text = text
        self.bright = bright
    }

    var body: some View {
        Text(verbatim: text)
            .font(TypeLevel.lowercased.font.weight(.semibold))
            .foregroundStyle(bright ? ColorRole.reason.color : ColorRole.text.color)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(
                (bright ? ColorRole.reason.color : ColorRole.text.color).opacity(0.16), in: Capsule()
            )
            .accessibilityLabel(Text(verbatim: text))
    }
}

extension View {

    /// The board shown when resolution fails (AP78): YouTube has changed or the
    /// video is blocked. With the jump into the YouTube app if it is installed —
    /// the trailer should still be viewable, just there.
    func trailerErrorBoard(_ youtubeID: Binding<String?>) -> some View {
        alert(
            Text(app: "detail.trailerUnavailable"),
            isPresented: Binding(
                get: { youtubeID.wrappedValue != nil },
                set: { if !$0 { youtubeID.wrappedValue = nil } })
        ) {
            if let id = youtubeID.wrappedValue, !id.isEmpty,
                let url = TrailerResolution.youtubeApp(id), TrailerPlayback.canOpen(url)
            {
                Button {
                    TrailerPlayback.open(url)
                } label: {
                    Text(app: "detail.trailerOpenYouTube")
                }
            }
            Button(role: .cancel) {
            } label: {
                Text(app: "common.ok")
            }
        } message: {
            Text(app: "detail.trailerUnavailableText")
        }
    }
}
