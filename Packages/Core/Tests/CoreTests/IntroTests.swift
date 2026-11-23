import Foundation
import SourceProbe
import Testing

@testable import Core

/// The catalog as it lies in the bundle — **the real file**, not a transcript.
///
/// **Why the real one:** The times belong in `intros.json` and not in the source code.
/// A test against a transcript would stay green if someone ruins the file while
/// touching up a clip — and on the TV the still frame would then run without
/// anybody learning why.
@Suite("AP51 · The intro catalog")
struct IntroCatalogTests {

    static let folder = CodeLocation.tvIntro.url

    static func catalog() throws -> IntroCatalog {
        try IntroCatalog.read(Data(contentsOf: folder.appending(path: "intros.json")))
    }

    @Test("The bundled file parses, and every file it names sits beside it")
    func fileAndFiles() throws {
        let catalog = try Self.catalog()
        #expect(catalog.clips.map(\.id) == ["waschbaer", "katze", "astronaut", "skater-girl", "opa"])
        for file in catalog.clips.map(\.file) + [catalog.fallbackStill] {
            #expect(
                FileManager.default.fileExists(atPath: Self.folder.appending(path: file).path),
                "\(file) is missing")
        }
        #expect(catalog.ringRingPosition == IntroCatalog.Placement(x: 0.78, y: 0.40))
    }

    /// The order of the points in time is the story: startup, ringing, reaction,
    /// exit — and the cards before the end at 5.04 s.
    @Test("Every clip tells its story in the right order and ends before 5.04 s")
    func timesInSequence() throws {
        for clip in try Self.catalog().clips {
            #expect(clip.trimStart < clip.bellAt, "\(clip.id)")
            #expect(clip.bellAt < clip.reactionAt, "\(clip.id)")
            #expect(clip.reactionAt < clip.exitAt, "\(clip.id)")
            #expect(clip.cardsAt < 5.042, "\(clip.id)")
            #expect(clip.cardsDeadline > 0, "\(clip.id)")
        }
    }

    /// **The deadline counts from the first displayed frame** — for the raccoon 1.1 s less
    /// than `cardsAt`. Without the subtraction the intro would last longer than the clip.
    @Test("The cards deadline is cardsAt minus trimStart, the still frame takes the shortest")
    func deadlines() throws {
        let catalog = try Self.catalog()
        let raccoon = try #require(catalog.clips.first { $0.id == "waschbaer" })
        #expect(abs(raccoon.cardsDeadline - 3.3) < 0.0001)
        #expect(abs(raccoon.bellAfterStart - 0.4) < 0.0001)
        let today = Date()
        let calendar = IntroCatalog.deviceCalendar
        let all: (String) -> Bool = { _ in true }
        #expect(
            abs(catalog.deadline(forItem: raccoon, on: today, calendar: calendar, available: all) - 3.3)
                < 0.0001
        )
        // The astronaut: 4.4 − 1.6 = 2.8 s — the shortest deadline.
        #expect(
            abs(catalog.stillFrameDeadline(on: today, calendar: calendar, available: all) - 2.8) < 0.0001)
        #expect(
            abs(catalog.deadline(forItem: nil, on: today, calendar: calendar, available: all) - 2.8) < 0.0001)
        // Without a single file the still frame calculates with the default set — never with 0.
        #expect(
            abs(catalog.stillFrameDeadline(on: today, calendar: calendar, available: { _ in false }) - 2.8)
                < 0.0001)
    }

    /// A fixed random value, so the test does not depend on luck.
    struct FixedRandom: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    @Test("Every character can be drawn, and an empty list yields none")
    func draw() throws {
        let catalog = try Self.catalog()
        var random = FixedRandom(state: 51)
        var drawn: Set<String> = []
        for _ in 0..<200 { drawn.insert(try #require(catalog.select(using: &random)).id) }
        #expect(drawn == Set(catalog.clips.map(\.id)))

        let empty = try IntroCatalog.read(
            Data(#"{"fallbackStill":"a.jpg","ringRingPosition":{"x":0,"y":0},"clips":[]}"#.utf8))
        #expect(empty.select(using: &random) == nil)
    }
}

/// **The cap: rule K and rule L** — tested at the connection, not at the number.
///
/// The clock is a hand clock: It only moves on when the test says so. That makes
/// "loading was shorter" and "loading was longer" a sequence and not a bet on the
/// machine's tempo.
@MainActor
@Suite("AP51 · The cover for the cards")
struct IntroCapTests {

    /// A clock that stands still until ``expires()`` lets it move on.
    final class ManualClock: @unchecked Sendable {
        private let stream: AsyncStream<Void>
        private let next: AsyncStream<Void>.Continuation
        private let lock = NSLock()
        private var _asked: [Duration] = []

        init() { (stream, next) = AsyncStream<Void>.makeStream() }

        var asked: [Duration] { lock.withLock { _asked } }

        func sleeper(_ duration: Duration) async throws {
            lock.withLock { _asked.append(duration) }
            for await _ in stream { return }
            throw CancellationError()
        }

        func expires() { next.yield() }
    }

    static func cover(_ clock: ManualClock, deadline: Duration = .seconds(4.4)) -> IntroCover {
        IntroCover(deadline: deadline) { try await clock.sleeper($0) }
    }

    /// Lets the cap's task run until it stands.
    static func letRun() async {
        for _ in 0..<200 { await Task.yield() }
    }

    /// **Rule K** — the Home screen is up before the deadline is over. The clock has not yet run out when the cap opens.
    @Test("Shorter loading: the cards arrive before the deadline passes")
    func shorter() async {
        let clock = ManualClock()
        let cover = Self.cover(clock)
        cover.start()
        await Self.letRun()
        #expect(cover.pending == nil)
        #expect(clock.asked == [.seconds(4.4)])

        cover.reportGlyphReady()
        #expect(cover.pending == .glyphReady)

        // The deadline after that changes nothing any more.
        clock.expires()
        await Self.letRun()
        #expect(cover.pending == .glyphReady)
    }

    /// **Rule L** — loading takes longer: The cap opens at the deadline **without**
    /// anyone having reported ready to draw. Before that it stays closed.
    @Test("Longer loading: the cards arrive at the deadline, not later")
    func longer() async {
        let clock = ManualClock()
        let cover = Self.cover(clock)
        cover.start()
        await Self.letRun()
        #expect(cover.pending == nil)

        clock.expires()
        await Self.letRun()
        #expect(cover.pending == .deadline)

        cover.reportGlyphReady()
        #expect(cover.pending == .deadline)
    }

    @Test("Glyph-ready before the start opens immediately, and the clock is never asked")
    func alreadyReady() async {
        let clock = ManualClock()
        let cover = Self.cover(clock)
        cover.reportGlyphReady()
        cover.start()
        await Self.letRun()
        #expect(cover.pending == .glyphReady)
        #expect(clock.asked.isEmpty)
    }

    @Test("Skipping opens immediately and stays the reason")
    func skip() async {
        let clock = ManualClock()
        let cover = Self.cover(clock)
        cover.start()
        cover.skip()
        #expect(cover.pending == .skipped)
        cover.reportGlyphReady()
        clock.expires()
        await Self.letRun()
        #expect(cover.pending == .skipped)
    }

    @Test("A second start does not set up a second clock")
    func startedTwice() async {
        let clock = ManualClock()
        let cover = Self.cover(clock)
        cover.start()
        cover.start()
        await Self.letRun()
        #expect(clock.asked == [.seconds(4.4)])
    }

    @Test("Whoever asks for the uncovering is called once: on uncovering or immediately")
    func afterUncovering() {
        let cover = Self.cover(ManualClock())
        var called = 0
        cover.afterUncovering { called += 1 }
        #expect(called == 0)
        cover.skip()
        #expect(called == 1)
        cover.reportGlyphReady()
        #expect(called == 1)
        cover.afterUncovering { called += 1 }
        #expect(called == 2)
    }
}

/// **On every cold start** — on-device test build 1332 (2026-09-27), as with the big streaming apps.
@Suite("When the intro plays")
struct IntroCadenceTests {

    /// **The finding:** Until build 1332 the clip hung on a daily flag in the
    /// default store; a second cold start on the same day showed nothing on the phone. The
    /// rule no longer knows a flag — only the read-aloud aid, motion and bundle.
    @Test("Every cold start shows the clip, even on the same day")
    func everyColdStart() {
        for _ in 0..<3 {
            #expect(
                IntroTiming.kind(voiceOver: false, reduceMotion: false, hasClip: true)
                    == .clip)
        }
    }

    /// **Returning from the background is not a new process:** Both stages remember
    /// the decided state statically, i.e. for the lifetime of the process — and nothing in
    /// a store that survived a restart.
    @Test("The stages decide once per process and remember nothing in a store")
    func oncePerProcess() throws {
        let paths = [
            "Packages/Features/Sources/Features/Shell/IntroStage.swift",
            "Phone/Packages/FeaturesPhone/Sources/FeaturesPhone/Intro/IntroStage.swift",
        ]
        for path in paths {
            let text = try String(
                contentsOf: SourceText.stem.appending(path: path), encoding: .utf8)
            #expect(text.contains("private static var decided"), "\(path)")
            #expect(!text.contains("UserDefaults"), "\(path)")
            #expect(!text.contains("Intromerker"), "\(path)")
        }
    }

    @Test("VoiceOver beats everything, reduced motion and a missing clip give the still frame")
    func kind() {
        #expect(
            IntroTiming.kind(voiceOver: true, reduceMotion: false, hasClip: true) == .none)
        #expect(
            IntroTiming.kind(voiceOver: false, reduceMotion: true, hasClip: true)
                == .stillFrame)
        #expect(
            IntroTiming.kind(voiceOver: false, reduceMotion: false, hasClip: false)
                == .stillFrame)
    }

    /// **Fade-out instead of cut-off** (on-device test build 1332): Opened by itself, it fades out
    /// longer than when skipped.
    @Test("Uncovered on its own the intro fades out, skipped it goes quickly")
    func fadeOut() {
        #expect(IntroTiming.fadeOut(after: .deadline) >= 0.8)
        #expect(IntroTiming.fadeOut(after: .glyphReady) == IntroTiming.fadeOut(after: .deadline))
        #expect(IntroTiming.fadeOut(after: .skipped) < IntroTiming.fadeOut(after: .deadline))
    }
}
