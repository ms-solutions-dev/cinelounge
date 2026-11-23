import AVFoundation
import Core
import Foundation
import Testing

@testable import Playback

/// The system engine on the playlist — checked without a stream.
///
/// What can be checked here are the engine's own computations and states: how it
/// loads, how it treats seeks, what it says about its buffer. The actual playing
/// needs a server and is left to the evenings of on-device use — but the faults that
/// stood out there all sat in exactly these computations: a silently discarded seek,
/// a "buffering" that was never set.
@MainActor
@Suite("The system engine")
struct NativeEngineTests {

    private var url: URL {
        URL(fileURLWithPath: "/tmp/cinelounge-nicht-vorhanden.mp4")
    }

    @Test("The loaded item gets the desired lead")
    func loadSetsForwardBuffer() {
        // Zero would mean: the engine decides on its own — and on the device it decided
        // tighter than the fluctuating server disk can bear.
        let engine = NativePlaybackEngine()
        engine.load(url, startingAt: 0)

        #expect(
            engine.player.currentItem?.preferredForwardBufferDuration
                == NativePlaybackEngine.forwardBufferSeconds
        )
        #expect(engine.player.automaticallyWaitsToMinimizeStalling)
    }

    @Test("A jump without a known length is performed instead of discarded")
    func seekWithoutDurationIsNotDropped() {
        // Shortly after opening the length is not there yet. The old rule "no seek without a
        // length" made every early seek ineffective: the bar showed the target, the film
        // kept playing at the old position.
        let engine = NativePlaybackEngine()
        engine.load(url, startingAt: 0)

        engine.seek(to: 250)

        #expect(engine.position == 250)
        #expect(engine.pendingStart == nil, "the jump is not merely remembered")
    }

    @Test("A jump below zero lands on zero")
    func seekClampsAtZero() {
        // Ten seconds back at second three — the everyday case. Unfiltered the bar would
        // run past the left edge, and the reported progress would be negative.
        let engine = NativePlaybackEngine()
        engine.seek(to: -7)

        #expect(engine.position == 0)
    }

    @Test("During a jump, the second one is only remembered")
    func secondSeekWaitsForTheFirst() {
        // A second `AVPlayer.seek` before the completion callback cancels the first.
        // Whoever scrubs fast collects nothing but cancelled seeks — the lock holds the last
        // request and executes it after the completion callback.
        let engine = NativePlaybackEngine()
        engine.load(url, startingAt: 0)

        engine.seek(to: 100)
        #expect(engine.isSeeking)
        #expect(engine.position == 100)

        engine.seek(to: 400)
        // The display stays during the running seek — the new target is taken only when the
        // engine is free for the next one.
        #expect(engine.position == 100)
    }

    @Test("The resume point is jumped to immediately on loading")
    func loadSeeksImmediately() {
        // Before, the point was remembered and caught up after the first time report — until
        // then the player loaded from minute zero: the server chunked a beginning nobody
        // wanted to see, and at chapter start that was a noticeable wait. AVFoundation
        // expressly allows the seek on a still-loading item; the first segment request thus
        // goes straight to the target. That the point lies within the film is ensured by the
        // callers — resume points and chapters arise from the metadata.
        let engine = NativePlaybackEngine()
        engine.load(url, startingAt: 942)

        #expect(engine.pendingStart == nil)
        #expect(engine.isSeeking, "the jump runs instead of being remembered")
        #expect(engine.position == 942, "the display is at the target immediately")
    }

    @Test("Without a loaded item there is no loaded range")
    func bufferedRangeNeedsAnItem() {
        // `nil` means for the UI: fall back to the fixed skip distance. An invented span
        // would be worse — it would declare seeks local that the engine cannot serve.
        let engine = NativePlaybackEngine()

        #expect(engine.bufferedRange == nil)
    }

    // MARK: - Why it failed

    @Test("The error code never goes out as an HTTP status")
    func errorCodeIsNeverCalledHTTP() {
        // `errorStatusCode` is described in the SDK header only as "A unique error code
        // identifier. Corresponds to «status»" (AVPlayerItem.h:1117-1121). What the number
        // means depends solely on the domain — -12642 is a CoreMedia value and no HTTP
        // status. A report that outputs it as one sends the search in the wrong direction.
        let text = NativePlaybackEngine.describe(
            NativePlaybackEngine.ErrorLogFacts(domain: "CoreMediaErrorDomain", code: -12642)
        )

        #expect(text.contains("CoreMediaErrorDomain"))
        #expect(text.contains("-12642"))
        #expect(!text.localizedCaseInsensitiveContains("HTTP"), "no HTTP word without evidence")
    }

    @Test("No error log is an answer of its own")
    func missingErrorLogSaysSo() {
        // For non-HTTP items the empty log is the normal case. Without a sentence of its
        // own, "nothing logged" could not be told apart from "not looked at" — and exactly
        // this kind of ambiguity has already cost the case days once.
        #expect(NativePlaybackEngine.describe(nil) == "no error log")
    }

    @Test("An HTTP response is reported only if one arrived")
    func httpResponseIsOnlyClaimedWhenReceived() {
        // According to the header `allHTTPResponseHeaderFields` is filled exactly "if an HTTP
        // response was received as part of this error" (AVPlayerItem.h:1135-1138). That
        // separates "the provider stayed silent" from "the provider answered with something
        // unusable" — an HTML page instead of video is half the finding with IPTV.
        let without = NativePlaybackEngine.describe(
            NativePlaybackEngine.ErrorLogFacts(domain: "NSURLErrorDomain", code: -1005)
        )
        #expect(!without.contains("HTTP-Antwort"))

        let using = NativePlaybackEngine.describe(
            NativePlaybackEngine.ErrorLogFacts(
                domain: "NSURLErrorDomain",
                code: -1005,
                httpHeaderCount: 9,
                contentType: "text/html"
            )
        )
        #expect(using.contains("HTTP response arrived (9 header lines)"))
        #expect(using.contains("text/html"))
    }

    @Test("Credentials in third-party text do not go into the trace")
    func credentialsInBorrowedTextAreDropped() {
        // Line 54 from diagnose/2026-08-23_1804_diagnose.log, in SHAPE: a passed-through
        // NSError took the full Xtream path with it, and in that path stand user name and
        // password — not in the query part but in the PATH. That is why the protection
        // recognizes the SHAPE of an address, instead of looking for a credential this
        // package does not know at all.
        //
        // **Host and credentials are invented.** On 2026-08-26 the real credential stood here,
        // copied letter for letter from the report — the test against the leak opened the
        // leak a second time, this time permanently in the source. Whoever touches this test
        // material: the length and the characters of the password segment carry the
        // statement, its content does not.
        let realLog =
            "Error Domain=NSURLErrorDomain Code=-1005 UserInfo={NSErrorFailingURLStringKey="
            + "http://203.0.113.7:80/live/play/RXJmdW5kZW5lclp1Z2FuZ0Z1ZXJEZW5UZXN0RGVy"
            + "TmljaHRzT2VmZm5ldEtlaW5FY2h0ZXNQYXNzd29ydDA9/340873}"

        let text = NativePlaybackEngine.describe(
            NativePlaybackEngine.ErrorLogFacts(
                domain: "NSURLErrorDomain",
                code: -1005,
                comment: realLog
            )
        )

        #expect(!text.contains("RXJmdW5kZW5lclp1Z2FuZ0Z1ZXJEZW5UZXN0RGVy"))
        #expect(!text.contains("://"))
    }

    @Test("A harmless comment is kept")
    func harmlessCommentSurvives() {
        // Counter-check: a protection that throws away every foreign text does protect, but
        // says nothing any more. The provider's comment is often the only information.
        let text = NativePlaybackEngine.describe(
            NativePlaybackEngine.ErrorLogFacts(
                domain: "NSURLErrorDomain",
                code: -1005,
                comment: "HTTP 404: File Not Found"
            )
        )

        #expect(text.contains("Comment: HTTP 404: File Not Found"))
    }

    @Test("A trace entry is exactly one line")
    func traceEntryStaysOnOneLine() {
        // `TraceRecorder.append` smooths `\n` when writing, but the display of the trace on
        // the TV does not (DiagnosticsSettings.swift:311) — and `\r` stays anyway. A line
        // break in the middle of foreign text broke the line apart there.
        let text = NativePlaybackEngine.describe(
            NativePlaybackEngine.ErrorLogFacts(
                domain: "CoreMediaErrorDomain",
                code: -12939,
                comment: "line one\nline two\rline three"
            )
        )

        #expect(!text.contains("\n"))
        #expect(!text.contains("\r"))
        #expect(text.contains("line one line two line three"))
    }

    @Test("The zero point is set with loading and falls with holding")
    func loadStartIsSetOnLoadAndClearedOnStop() {
        // Without the clearing in `stop()` the next failure line measures against a target
        // that is no longer playing — then the span would no longer be a measurement but a
        // claim.
        let engine = NativePlaybackEngine()
        #expect(engine.loadStartedAt == nil)

        engine.load(url, startingAt: 0)
        #expect(engine.loadStartedAt != nil)

        engine.stop()
        #expect(engine.loadStartedAt == nil)
    }
}
