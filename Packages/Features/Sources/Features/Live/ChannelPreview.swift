import Core
import DesignSystem
import Playback
import SwiftUI

/// The channel in focus as a running picture, at the place of its logo.
///
/// **Its own host and therefore its own engine**, for the same reason as with the trailer:
/// the preview runs next to the Live area and not in playback. A
/// shared host would mean that opening a channel inherits the running preview
/// stream — you would hear two audio tracks on top of each other.
///
/// **The sound stays off.** A preview that talks along while browsing is unbearable in the
/// living room; you want to see what is on, not hear it. And because on
/// every move a different channel would start, it would be an audio change
/// every second.
///
/// **It gives up its stream before playback starts.** That is the condition
/// under which it is justifiable at all on an account with a single allowed connection:
/// two streams are never open at the same time. The release happens in
/// ``LiveView`` immediately before opening — here ``onDisappear`` suffices, because the
/// view disappears in the process.
///
/// **And it remuxes itself** (on-device finding 2026-08-15, seventh evening test: "the
/// preview doesn't play"): a raw transport stream went here unwrapped to
/// Apple's engine — black. VLC used to catch this case; with its removal
/// the preview needs the same remuxer path as playback, including abort on
/// moving on: while browsing, the channel changes faster than a
/// remuxer is up, and two builds at once cost the one connection.
struct ChannelPreview: View {

    let target: PlaybackTarget
    let size: CGSize

    @State private var host = EngineHost()

    /// Watches whether a picture actually arrives — see ``watchForBlindStream()``.
    @State private var watchdog: Task<Void, Never>?

    /// The running remuxer build — to be aborted on moving on, otherwise
    /// two builds at once hold the one provider connection (the same lesson as
    /// with zapping in ``PlayerModel``).
    @State private var build: Task<Void, Never>?
    /// The standing remuxer — held for as long as its picture runs.
    @State private var session: LiveRemuxSession?
    /// Its playlist — remembered for the handoff to the successor.
    @State private var playlist: URL?
    /// The source the session is really attached to. **Not `target.url`:**
    /// on a channel switch `target` already carries the successor while the
    /// session still belongs to the predecessor — whoever parked it under the new address
    /// would hand the consumer the wrong channel.
    @State private var sessionSource: URL?
    /// Counts the starts, so that only the most recent build gets its engine.
    @State private var generation = 0

    var body: some View {
        VideoSurface(host: host)
            .frame(width: size.width, height: size.height)
            // systemfarbe: black behind it — a channel in 4:3 format has bars at the sides, and these
            // should be black and not let the base surface show through.
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: MetricsBoard.tv.fieldRadius, style: .continuous))
            // The board is its own focus section with two buttons in it. A
            // surface that accepts hits would draw the focus to itself — and thus stand
            // between the channel list and "Play".
            .allowsHitTesting(false)
            .onAppear { start(target) }
            // If the channel changes without the view being recreated, the
            // previous one would otherwise keep running: nothing would be visible, but on the provider's connection
            // everything.
            .onChange(of: target.id) { _, _ in start(target) }
            .onDisappear {
                watchdog?.cancel()
                watchdog = nil
                tearDown()
                host.stop()
            }
    }

    /// How long the focus must rest before the preview
    /// opens a connection.
    ///
    /// **The dwell threshold is connection protection, not sluggishness**
    /// (on-device finding 2026-08-16, proven by response status): while browsing,
    /// every preview opened its connection immediately, while that of the
    /// previous one was still half open — the one-connection panel answered the
    /// next one with 403, and exactly the channels you then
    /// stopped on showed nothing. Whoever browses now opens no
    /// connections at all; whoever lingers gets their picture three quarters of a second
    /// later — and reliably.
    private static let settleDelay: Duration = .milliseconds(700)

    /// Starts the preview for a target — through the remuxer where the
    /// decision calls for it, otherwise directly.
    private func start(_ next: PlaybackTarget) {
        generation += 1
        let mine = generation
        tearDown()

        // Do not leave a picture of the previous channel standing while waiting and
        // building — and its connection is needed right away by the successor.
        host.stop()
        build = Task { @MainActor in
            // Dwell first — the reasoning is documented at ``settleDelay``. Moving
            // on aborts this task before anything touches the
            // network.
            try? await Task.sleep(for: Self.settleDelay)
            guard mine == generation, !Task.isCancelled else { return }

            guard next.decision.runsOverRepacker else {
                host.start(next)
                watchForBlindStream()
                return
            }
            // **The preview always takes the HLS path.** If the viewer has chosen the
            // direct renderer, that applies to playback; the preview
            // is a bonus and needs no second renderer. Its decision
            // is therefore redirected here — otherwise the host would get a
            // renderer without a buffer.
            let hls = next.decision.asRepacker()

            // Ask only at the handoff point: if the session of THIS channel is still running there,
            // the preview plays on on it immediately. A
            // foreign one is torn down in the process — BEFORE connecting right
            // away, not in a race (the 403 lesson, see ``LiveHandover``).
            if let held = LiveHandover.shared.claim(for: next.url) {
                session = held.session
                playlist = held.playlist
                sessionSource = held.source
                host.start(next.rerouted(to: held.playlist, decision: hls))
                return
            }

            do {
                let fresh = try LiveRemuxSession(
                    source: next.url, label: "Vorschau \(next.title)")
                let url = try await fresh.start()
                guard mine == generation, !Task.isCancelled else {
                    fresh.stop()
                    return
                }
                session = fresh
                playlist = url
                sessionSource = next.url
                host.start(next.rerouted(to: url, decision: hls))
            } catch {
                // bewusst still: a preview that cannot play shows the logo —
                // it is a bonus, not a promise. The session tore itself down when it threw
                // (zombie lock).
            }
        }
    }

    // The preview plays WITH sound (user decision 2026-08-16): it had been described and
    // built as muted — but the viewer expects it like the
    // trailers, with sound. The dwell threshold takes away from browsing the
    // audio change every second that had motivated the old rule.

    /// Hands over build and session — the session goes to the handoff point.
    ///
    /// **Parked, not stopped:** whoever wants to play live next —
    /// playback of the same channel or the next preview — picks it up
    /// there or clears it away in the right order. If nobody
    /// picks it up, the handoff point's deadline stops it after two seconds.
    private func tearDown() {
        build?.cancel()
        build = nil
        if let session, let playlist, let sessionSource {
            LiveHandover.shared.park(
                .init(source: sessionSource, session: session, playlist: playlist))
        } else {
            session?.stop()
        }
        session = nil
        playlist = nil
        sessionSource = nil
    }

    /// How long to wait for a picture before the raw stream gets its turn.
    ///
    /// The same deadline as in playback (``PlayerModel/blindTicks``) and for the
    /// same reason: Apple's player accepts a playlist with HEVC in
    /// MPEG-TS, keeps playing it silently and shows nothing.
    private static let blindDelay: Duration = .seconds(2.5)

    /// Fetches the raw stream if the preview stays blind.
    ///
    /// **The preview has to be able to do this itself** (viewer finding 2026-08-08: "some
    /// previews work, others don't"). Otherwise the memory only fills
    /// when a channel was opened **completely** — whoever merely browses the list
    /// would see a black board on every channel not yet known.
    /// What is noticed here then also applies to playback: both read the
    /// same memory. The raw stream goes through ``start(_:)`` and thus
    /// through the remuxer — since the VLC removal nobody can play it unwrapped.
    private func watchForBlindStream() {
        watchdog?.cancel()
        guard target.url.pathExtension.lowercased() == "m3u8" else { return }

        watchdog = Task { @MainActor in
            try? await Task.sleep(for: Self.blindDelay)
            guard !Task.isCancelled, host.isRunning,
                host.controller.hasVideoOutput == false
            else { return }

            var memory = RawStreamMemory.load(from: SecureStore())
            memory.remember(target.url)
            memory.save(to: SecureStore())
            // **And the kind learns along** (AP3 · V5): the preview sees more
            // channels than playback ever gets to see — whoever browses through a
            // group thereby feeds exactly the rule that opens the next
            // channel of the same kind without a blind attempt.
            var rule = RawStreamRule.load(from: SecureStore())
            rule.rememberRaw(
                RawStreamRule.pair(counterpart: target.url.host, name: target.title))
            rule.save(to: SecureStore())

            let raw = target.url.deletingPathExtension().appendingPathExtension("ts")
            start(
                PlaybackTarget(
                    itemID: nil,
                    title: target.title,
                    url: raw,
                    decision: PlaybackEngineSelector.decide(
                        for: MediaSource(container: .ts),
                        sourceCanStartAtOffset: false,
                        canDecodeHEVC: DeviceCodecs.hasHEVC
                    ),
                    kind: .live
                )
            )
        }
    }
}
