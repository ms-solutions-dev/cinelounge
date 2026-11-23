import Core
import Diagnose
import Flows
import Foundation
import JellyfinKit
import Playback

/// The remuxer on the phone — **connected, not rebuilt.**
///
/// **The finding of 2026-09-06, measured on the device:** of the two provider accesses in
/// this setup, none of the channels of one played on the phone. It allows only `ts`; the
/// app built `…/2.m3u8`, got 407, fell back to `…/2.ts` — and Apple's engine plays MPEG-TS
/// **only inside an HLS playlist**, never raw (`AVFoundationErrorDomain -11850`).
///
/// **On the TV the same channel ran, because the app remuxes itself there.**
/// `JellyfinPlayerSource.isServable(_:)` spelled out the gap literally since the first
/// day: *"The own remuxer is not connected on the phone."*
///
/// **And that is exactly what it was: not connected, not missing.** The schedule counted
/// on a port — "bring `SampleQueue` and `SampleBufferPlaybackEngine` into the phone
/// project". Checked, both have long been where both apps share them: ``LiveRemuxSession``,
/// ``SampleQueue``, `TransportRemuxer` and the transport stream reader in `Core`, the
/// engine in `Playback`, and `EngineHost.start(_:samples:)` has always accepted the sample
/// queue. What was missing are the thirty lines here.
///
/// **Two sessions, three exits — and the choice is not a matter of taste.**
///
/// The **stream** of a channel has no start and no end; it is read as it comes
/// (``LiveRemuxSession``). A **file** has both and in addition a seek table: it is fetched
/// in ranges, and that is why one can jump in it (``MatroskaFileSession`` over
/// ``HTTPByteRangeSource``). Two facts, two readers — anyone who sent the file through the
/// stream reader would get a film without scrubbing and would have to read it from the
/// start to get to the middle.
///
/// * **The direct renderer** (`renderInApp`, channels only) hands the packets to a
///   ``SampleQueue`` and from there to `AVSampleBufferDisplayLayer`. It waits for **no
///   chunk** — measured on the TV: 5.0 s to the picture via chunks against 376–678 ms
///   direct.
/// * **The playlist of a channel** (`remuxInApp`, `kind == .live`) writes chunks and gives
///   the system player an HLS playlist on `127.0.0.1`. Slower in startup, but with
///   everything the system player brings.
/// * **The playlist of a file** (`remuxInApp`, everything else) does the same, but builds
///   the chunks **on demand** from the Matroska on the server. The path was not built on
///   the phone until 2026-09-07, and that was the finding of the day: a title of the media
///   server got the raw file and `AVFoundationErrorDomain -11828` — the stream reader was
///   the only exit, so none ran.
///
/// **Decoding is done in all cases by the same hardware.** The project rule "audio may be
/// decoded yourself, video not" is kept: it is the **container** that is repacked, not the
/// picture.
@MainActor
public enum RepackagerRun {

    /// What a started run returns.
    public struct Run {
        /// The address that the engine gets. With the direct renderer it is the source itself —
        /// it does not read from there, but the engine needs an identifier.
        public let address: URL
        /// The sample queue, if rendering is direct.
        public let samples: SampleQueue?
        /// Ends the run. **Must be called**, otherwise the session holds on to the one allowed
        /// connection of the provider.
        public let finish: @MainActor () -> Void

        /// The running session — **and this run is its holder.** It is needed only for ending;
        /// the live diagnostics that read its numbers were dropped on 2026-09-07 — the diagnostics
        /// switch in the settings writes the same numbers into the report, and a second screen for
        /// that was one too many.
        ///
        /// **Until 2026-09-07 this said `weak`, and that was the reason a channel stood forever after
        /// the first teardown.** Found on Telve 1 HQ in the simulator: "Connection dropped (no. 1) —
        /// new attempt in 0.5 s", then two minutes without a line, the picture froze at 64 ms of
        /// supply. The session had **no strong holder**: the TV holds it in
        /// `PlayerModel.remuxHandle`, the phone held it only here — weakly — and nowhere else. It
        /// stayed alive solely through the running `URLSessionDataTask`, which holds its delegate.
        /// When the task ends because the connection dropped, it lets go, the session dies, and
        /// the scheduled reconnector (`Task { [weak self] … }`) finds nobody. No error, no tally,
        /// no line — exactly the picture from the trace.
        ///
        /// The concern of back then — a run that holds the one allowed connection of the provider
        /// — is answered with ``finish``, not with a weak reference: whoever ends the run calls
        /// `stop()`, and ``PlayerModel`` drops the run afterwards. Proven in `PlayerChainTests`:
        /// the run holds what it is supposed to end.
        ///
        /// **`AnyObject` and no common protocol**, since the file has its own reader (2026-09-07): here
        /// stands a ``LiveRemuxSession`` or a ``MatroskaFileSession``. **What is read since
        /// 2026-09-25 is the pulse** (see ``pulse``), and only the stream has one; a common protocol
        /// for both would still have no content. **Ending remains solely via ``finish``** — that is
        /// the only way there is supposed to be.
        let session: AnyObject

        /// The counters of the remuxer for the stall interpretation — `nil` on the file path.
        ///
        /// **Only the stream has a pulse.** ``LiveRemuxSession`` fulfils ``Core/RepackerPulse`` in
        /// `Core`; ``MatroskaFileSession`` does not, and the file path stays without
        /// interpretation — as on the TV, where a dead writer of the file reports itself.
        public var pulse: (any RepackerPulse)? { session as? RepackerPulse }

        /// A corrected start position — the requested one lies beyond the end of a truncated file
        /// (AP58 R4, ``Flows/RemuxStart/tooShort(startAt:duration:)``).
        public var startAt: TimeInterval? = nil

        /// A sentence for the viewer — that the file is truncated.
        public var hint: String? = nil

        init(
            address: URL, samples: SampleQueue?, finish: @escaping @MainActor () -> Void,
            session: AnyObject, startAt: TimeInterval? = nil, hint: String? = nil
        ) {
            self.address = address
            self.samples = samples
            self.finish = finish
            self.session = session
            self.startAt = startAt
            self.hint = hint
        }

        /// From the shared setup.
        init(_ started: RemuxStart.Started) {
            self.init(
                address: started.address, samples: started.samples, finish: started.finish,
                session: started.handle, startAt: started.startAt, hint: started.hint)
        }
    }

    /// Whether this target needs a remuxer at all.
    ///
    /// **By the delivery path and not by the file extension.** An address that ends in `.ts`
    /// can be an HLS playlist, and one without an extension a raw stream; what applies was
    /// decided by the source and laid down in the ``PlaybackDecision``.
    public static func isNeeded(_ target: PlaybackTarget) -> Bool {
        target.decision.delivery == .renderInApp || target.decision.delivery == .remuxInApp
    }

    /// Starts the remuxer for this target — **via the shared setup**
    /// (AP58 R4, ``Flows/RemuxStart``).
    ///
    /// **And the playlist with a start marker**, when a recording is continued over the
    /// chunking of the server: without it the player first fetched chunk 0 (on the TV, forty
    /// seconds without a picture). If it does not succeed, the engine plays the playlist
    /// itself — a note, not an abort.
    ///
    /// - Returns: `nil` if none is needed — then the system player plays directly.
    /// - Throws: What the session throws. **Passed on and not swallowed:** what becomes of it
    ///   is decided by ``Flows/RemuxStart/fallback(after:target:sourceIsChunked:)``
    ///   in ``PlayerModel``.
    public static func start(_ target: PlaybackTarget) async throws -> Run? {
        if RemuxStart.needsStartMark(target) {
            do {
                return Run(try await RemuxStart.startMark(target))
            } catch {
                Diagnose.hint(.playback, "Continue Watching: list not rewritten", error)
                return nil
            }
        }
        guard isNeeded(target) else { return nil }
        // **No preview to take over** — the phone has none; the memory of the tight suppliers is
        // kept only by the TV, but it is read here all the same.
        return Run(
            try await RemuxStart.build(
                target,
                environment: RemuxStart.Context(
                    store: SecureStore(), takesOverPreview: false,
                    timeOffset: TimeShift.capacity(.phone))))
    }
}
