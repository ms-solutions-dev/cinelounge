import Core
import Foundation
import Testing

@testable import Features

/// **The connection from the Home screen to the intro's lid** (AP51, 2026-09-24).
///
/// **Why here and not only in `Core`:** The lid alone proves that it opens on a
/// ready-to-draw signal. Whether that signal ever **comes** is decided by the Home screen —
/// and exactly this line is the one that can silently break: A lid that nobody reports to
/// opens anyway, namely at the deadline. The intro would then extend every launch in the
/// multi-profile household to `cardsAt`, and no check that only looks at the lid would turn
/// red.
///
/// So the whole path is checked: ``HomeModel`` loads and reports to a
/// ``DrawReadiness`` that is hooked to the ``Core/IntroCover`` via
/// ``DrawReadiness/connect(_:)`` — the same line the view calls.
@MainActor
@Suite("AP51 · From Home to the intro cover")
struct IntroConnectionTests {

    /// A latch that opens only when the check says so.
    final class Latch: @unchecked Sendable {
        private let stream: AsyncStream<Void>
        private let next: AsyncStream<Void>.Continuation
        init() { (stream, next) = AsyncStream<Void>.makeStream() }
        func wait() async throws {
            for await _ in stream { return }
            throw CancellationError()
        }
        func to() { next.yield() }
    }

    /// A source whose libraries only come when its latch opens — or that fails.
    final class StartSource: ContentSource, @unchecked Sendable {
        nonisolated var displayName: String { "Intro-Doppel" }
        nonisolated var canStartAtOffset: Bool { false }
        /// **A test double tracks its own state** — nobody should wrap it.
        nonisolated var tracksStateItself: Bool { true }

        let lock: Latch?
        let fails: Bool

        init(lock: Latch? = nil, fails: Bool = false) {
            self.lock = lock
            self.fails = fails
        }

        nonisolated func imageURL(
            itemID: String, kind: ImageKind, width: Int, tag: String?
        )
            -> URL?
        { nil }

        func libraries() async throws -> [Core.Library] {
            try await lock?.wait()
            if fails { throw Missing.nothing }
            return [Core.Library(id: "filme", name: "Filme", kind: .movies)]
        }
        func items(in library: Core.Library.ID, filter: ItemFilter) async throws -> [MediaItem] {
            [MediaItem(id: "f1", kind: .movie, title: "Ein Film")]
        }
        func item(id: String) async throws -> MediaItem { throw Missing.nothing }
        func children(of itemID: String) async throws -> [MediaItem] { [] }
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

    /// A lid on a clock that only runs out on cue — and already connected.
    static func setup(source: StartSource) -> (HomeModel, IntroCover, Latch) {
        let clock = Latch()
        let cap = IntroCover(deadline: .seconds(4.4)) { _ in try await clock.wait() }
        let readiness = DrawReadiness()
        readiness.connect(cap)
        cap.start()
        let store = InMemoryStore()
        let model = HomeModel(source: source, store: store, shelfStore: store)
        model.drawReadiness = readiness
        return (model, cap, clock)
    }

    static func letRun() async {
        for _ in 0..<200 { await Task.yield() }
    }

    /// **Rule K at the line:** The Home screen is done, the clock is still running — and the
    /// lid is open all the same.
    @Test("Home can draw before the deadline is up: the cards come earlier")
    func earlier() async {
        let (model, cap, _) = Self.setup(source: StartSource())
        await Self.letRun()
        #expect(cap.pending == nil)

        await model.load()
        guard case .ready = model.state else {
            Issue.record("Home not ready: \(model.state)")
            return
        }
        #expect(cap.pending == .glyphReady)
    }

    /// **Rule L at the line:** The Home screen is still loading, the deadline has passed — the
    /// lid is open, and the Home screen is still at `.loading`: The cards come with
    /// placeholders, the intro does not wait.
    @Test("Home takes longer: the cards come at the deadline, with placeholders")
    func onTime() async {
        let lock = Latch()
        let (model, cap, clock) = Self.setup(source: StartSource(lock: lock))
        let load = Task { await model.load() }
        await Self.letRun()
        #expect(model.state == .loading)
        #expect(cap.pending == nil)

        clock.to()
        await Self.letRun()
        #expect(cap.pending == .deadline)
        #expect(model.state == .loading)

        // And the loading runs to its end underneath — it never hung on the lid.
        lock.to()
        await load.value
        guard case .ready = model.state else {
            Issue.record("Home not ready: \(model.state)")
            return
        }
        #expect(cap.pending == .deadline)
    }

    /// **A fault is a result**, and the intro must not cover it.
    @Test("A failure also opens the cover")
    func disruptionCounts() async {
        let (model, cap, _) = Self.setup(source: StartSource(fails: true))
        await model.load()
        #expect(model.state.isFailed)
        #expect(cap.pending == .glyphReady)
    }

    /// Whoever reports before the intro registers counts all the same.
    @Test("Whoever registers after the notification is called immediately")
    func registeredLate() {
        let readiness = DrawReadiness()
        readiness.notify()
        let cap = IntroCover(deadline: .seconds(4.4)) { _ in }
        readiness.connect(cap)
        #expect(cap.pending == .glyphReady)
    }

    /// **"Who's watching?" waits for the lid** (counter-check 2026-09-24): If the full screen
    /// appeared at once, it would lie over the clip, and in the multi-profile household nobody
    /// would see a frame of it.
    @Test("\"Who's watching?\" appears only when the deadline opens the intro")
    func whoIsWatchingWaits() async {
        let clock = Latch()
        let cap = IntroCover(deadline: .seconds(4.4)) { _ in try await clock.wait() }
        let readiness = DrawReadiness()
        readiness.connect(cap)
        cap.start()
        var shown = false
        readiness.afterIntro { shown = true }
        await Self.letRun()
        #expect(!shown)

        clock.to()
        await Self.letRun()
        #expect(cap.pending == .deadline)
        #expect(shown)
    }

    @Test("\"Who's watching?\" also appears when Home is ready first")
    func whoIsWatchingAfterHome() async {
        let (model, cap, _) = Self.setup(source: StartSource())
        var shown = false
        model.drawReadiness.afterIntro { shown = true }
        #expect(!shown)
        await model.load()
        #expect(cap.pending == .glyphReady)
        #expect(shown)
    }

    @Test("Without an intro \"Who's watching?\" appears immediately")
    func withoutIntroImmediate() {
        var shown = false
        DrawReadiness().afterIntro { shown = true }
        #expect(shown)
    }
}
