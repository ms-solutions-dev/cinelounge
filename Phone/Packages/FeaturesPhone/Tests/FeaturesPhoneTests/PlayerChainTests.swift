import Core
import Diagnose
import Foundation
import Playback
import Testing

@testable import FeaturesPhone

#if canImport(UIKit)
    import AVFAudio
#endif

/// The four places where the market fails in droves — **and the player had
/// no check at all until 2026-09-06**
///
/// 1.214 lines, and exactly the chain in which the heaviest findings lie. From the
/// market research: picture-in-picture, lock screen, subtitle switching and
/// resume position repeatedly break through updates in Swiftfin. Swiftfin #1400
/// names the worst state by name: *"iOS thinks it is playing, the audio is not
/// playing"* — the intermediate state is worse than no feature.
///
/// **What is checked is what can be checked without a device:** the conditions under which a button
/// appears, and the information the chain hangs on. Whether AVFoundation then does the
/// right thing is checked by no test suite — the screen checks that.
@Suite("Player chain")
struct PlayerChainTests {

    private static func job(
        kind: PlaybackTarget.Kind = .recording, startAt: TimeInterval = 0,
        duration: TimeInterval? = 5400, subtitles: [PlaybackTrack] = []
    ) -> PlaybackRequest {
        PlaybackRequest(
            identifier: "title", title: "A Film", address: URL(string: "https://beispiel.test/a")!,
            startAt: startAt, duration: duration, subtitles: subtitles,
            image: URL(string: "https://beispiel.test/plakat.jpg"), kind: kind)
    }

    // MARK: - 1 · The lock screen

    /// **A channel gets no skip buttons.** `PlaybackTarget.isSeekable` says
    /// the same; on the lock screen nobody can look up why a button does
    /// nothing.
    @Test("Only a recording can be scrubbed")
    func onlyRecordingSeekable() {
        #expect(Self.job(kind: .recording).target.isSeekable)
        #expect(!Self.job(kind: .live).target.isSeekable)
    }

    /// **A channel writes no progress.** "Watched 40 %" over a running
    /// program is a number without meaning — and in the "Continue Watching" shelf an
    /// invitation to something that no longer exists.
    @Test("Only a recording reports progress")
    func onlyRecordingReports() {
        #expect(Self.job(kind: .recording).belongsInHistory)
        #expect(!Self.job(kind: .live).belongsInHistory)
        #expect(Self.job(kind: .live).target.itemID == nil)
    }

    // MARK: - 2 · The resume position

    /// **The competition's most common error, and it is a calculation.** Whoever stopped at minute
    /// 17 wants to continue there — even if they last watched on the TV.
    @Test("The start position travels along and is not thrown away")
    func startPositionStays() {
        #expect(Self.job(startAt: 1020).target.startAt == 1020)
        #expect(PlaybackJob(identifier: "x", startAt: 1020).startAt == 1020)
        // **`nil` means "ask the server" and not "from the start".** Zero explicitly means
        // from the start — two different things, and mixing them up costs the position.
        #expect(PlaybackJob(identifier: "x").startAt == nil)
        #expect(PlaybackJob(identifier: "x", startAt: 0).startAt == 0)
    }

    /// **Only between the first and the last percent.** A bar at 0 % says "something
    /// has been started here", and that is then not true; one at 100 % says it too,
    /// and then it is over.
    @Test("Progress is shown only where it means something")
    func progressBounds() {
        let film = Self.job(duration: 6000)
        #expect(film.portion(at: 0) == nil)
        #expect(film.portion(at: 5990) == nil)
        #expect(film.portion(at: 3000) == 0.5)
        // Without a known duration there is no fraction — and no invented number.
        #expect(Self.job(duration: nil).portion(at: 100) == nil)
    }

    // MARK: - 3 · The subtitle switch

    /// **Gone instead of grayed out.** A title without a subtitle track gets no button that
    /// has nothing to choose — same rule as for the source choice next to it.
    @Test("No subtitle button without a subtitle track")
    func subtitleButton() {
        #expect(Self.job().subtitles.isEmpty)
        let using = Self.job(subtitles: [
            PlaybackTrack(id: 1, rawName: "Deutsch", language: "deu")
        ])
        #expect(!using.subtitles.isEmpty)
    }

    // MARK: - 4 · Picture in picture and the audio session

    /// **The audio session is the prerequisite and not a side item.** Without the category
    /// `.playback` iOS does not even offer picture-in-picture — which is why this suite checks
    /// that the session has a way at all to pause the player.
    @MainActor
    @Test("The audio session carries both commands")
    func audioSessionCommands() {
        var halted = false
        var resumed = false
        let commands = AudioSession.Commands(
            stop: { halted = true }, resume: { resumed = true })
        commands.stop()
        commands.resume()
        #expect(halted)
        #expect(resumed)
    }

    /// **Unplugged headphones pause, plugged-in ones do not.** Apple's own rule and
    /// the only right one: The movie would otherwise keep playing over the speaker, on the train.
    @Test("Every reason for an audio route change has a sentence")
    func audioRouteSentences() {
        #if canImport(UIKit)
            for reason in [
                AVAudioSession.RouteChangeReason.newDeviceAvailable, .oldDeviceUnavailable,
                .categoryChange, .override, .wakeFromSleep, .noSuitableRouteForCategory,
                .routeConfigurationChange, .unknown,
            ] {
                #expect(!AudioSession.wording(reason).isEmpty)
            }
        #endif
    }

    /// **All six phone events have a sentence and a place.** Without them one afterwards sees
    /// only "it stopped".
    @Test("Every phone event carries sentence, area and severity")
    func eventsComplete() {
        #expect(PhoneEvent.allCases.count == 6)
        for event in PhoneEvent.allCases {
            #expect(!event.message.isEmpty)
        }
        // The memory warning is the harbinger of termination and **always** goes in the ledger,
        // not only with verbose recording.
        #expect(PhoneEvent.memoryWarning.severity != .step)
        #expect(PhoneEvent.interrupted.severity != .step)
    }
}

/// The repackager — **the chain from the raw stream to the engine.**
///
/// The finding of 2026-09-06, measured on the device: Of the two provider accesses of this
/// household, none of the first one's channels played on the phone. It allows only `ts`; the app
/// built `…/2.m3u8`, got 407, fell back to `…/2.ts` — and Apple's engine plays MPEG-TS
/// **only inside an HLS playlist** (`AVFoundationErrorDomain -11850`).
///
/// **What is checked here and what is not.** What is checked is the choice: that a raw stream
/// gets the repackager and nothing else does. Whether `AVSampleBufferDisplayLayer` then
/// shows a picture is checked by the screen — that needs a provider, a network and
/// a device.
@MainActor
@Suite("Repackager")
struct RepackagerTests {

    static func channel(_ address: String) -> PlaybackRequest {
        PlaybackRequest(
            identifier: "s1", title: "A Channel", address: URL(string: address)!,
            origin: .channelList, kind: .live)
    }

    /// **A raw stream gets the repackager.** Without it, it ends in a black
    /// picture, and on every single channel of this access. **Since AP58 G1 through the
    /// own playlist and not the direct renderer** (A1): Only it sets up the time-offset
    /// ring — same specification as on the TV.
    @Test("A raw transport stream is repackaged — via the playlist with a time offset")
    func rawStreamIsRepackaged() {
        let target = Self.channel("http://beispiel.invalid:2086/live/nutzer/pass/2.ts").target
        #expect(target.decision.delivery == .remuxInApp)
        #expect(target.decision.engine == .native)
        #expect(RepackagerRun.isNeeded(target))
    }

    /// **An HLS playlist does not.** The system player can handle it, and it can do more than
    /// the direct renderer — using the latter there would be an engine without reason. **Since AP58 R4
    /// the path is called `directPlay`, as on the TV** (``Core/ChannelAddressChoice``): The playlist
    /// goes unchanged to the system player; the engine reads the delivery path only for the log.
    @Test("An HLS playlist keeps playing via the system player")
    func hlsStaysNative() {
        let target = Self.channel("http://beispiel.invalid:2086/live/nutzer/pass/2.m3u8").target
        #expect(target.decision.delivery == .directPlay)
        #expect(target.decision.engine == .native)
        #expect(!RepackagerRun.isNeeded(target))
    }

    /// **A movie does not, even if the address ends in `.ts`.** The direct renderer cannot
    /// seek; a movie without seeking would be the worse trade — and the
    /// media server repackages on its own anyway.
    @Test("Only channels are repackaged, not recordings")
    func channelsOnly() {
        let film = PlaybackRequest(
            identifier: "f1", title: "A Film",
            address: URL(string: "http://beispiel.invalid/film.ts")!,
            origin: .jellyfin, kind: .recording)
        #expect(film.target.decision.delivery == .hls)
        #expect(!RepackagerRun.isNeeded(film.target))
    }

    /// **The run holds its session — strongly.** Finding of 2026-09-07 on Telve 1 HQ: After the
    /// first drop a new handle never came, because the session was held only weakly and
    /// died with the end of the network task. Here the only other holder is released;
    /// if the session is still standing afterwards, the run is its holder.
    @Test("The run holds its session until it ends")
    @MainActor
    func runHoldsSession() throws {
        let samples = SampleQueue(label: "check")
        var session: LiveRemuxSession? = try LiveRemuxSession(
            source: URL(string: "http://beispiel.invalid:2086/live/nutzer/pass/2.ts")!,
            label: "check", samples: samples)
        weak let observed = session
        let run = RepackagerRun.Run(
            address: URL(string: "http://beispiel.invalid/2.ts")!, samples: samples,
            finish: { [session] in session?.stop() }, session: session!)
        session = nil
        #expect(observed != nil, "without a holder the session dies with the first network task")
        // **Pin down first, then compare.** Since ``RepackagerRun/Run/session`` is held as
        // `AnyObject` (the switch between channel and file session), the compiler
        // crashes on a direct `===` against the weak reference —
        // Swift 6.3.3, when generating the reabstraction thunk. Two named values
        // avoid it and check the same thing.
        let held: AnyObject? = run.session
        let expected: AnyObject? = observed
        #expect(held === expected)
        run.finish()
        withExtendedLifetime(run) {}
    }

    /// **The redirect remembers which channel it was.**
    ///
    /// The repackager builds a playlist on `127.0.0.1`; whoever afterwards asks for the channel —
    /// switching, program, favorite tag — would otherwise get the address of the own
    /// web server. Exactly that was behind two outages of 2026-08-11 in the sister project.
    @Test("After the redirect the channel is still recognisable")
    func redirectKeepsOrigin() {
        let target = Self.channel("http://beispiel.invalid:2086/live/nutzer/pass/2.ts").target
        let redirected = target.redirected(to: URL(string: "http://127.0.0.1:8088/l.m3u8")!)

        #expect(redirected.url.host() == "127.0.0.1", "the engine goes to the repackager")
        #expect(redirected.sourceURL == target.url, "the channel stays recognisable")

        // **Redirecting twice does not overwrite the first origin.**
        let again = redirected.redirected(to: URL(string: "http://127.0.0.1:8089/l.m3u8")!)
        #expect(again.sourceURL == target.url)
    }

    /// **The redirect is not recognized by the file name.** An address without an extension is
    /// the normal case with the portals and arrives as a finished MP4.
    @Test("A portal address without an extension stays untouched")
    func portalWithoutExtension() {
        let target = PlaybackRequest(
            identifier: "p1", title: "An Episode",
            address: URL(string: "https://host.invalid/abc123")!,
            origin: .portals, kind: .recording)
        #expect(!RepackagerRun.isNeeded(target.target))
    }
}
