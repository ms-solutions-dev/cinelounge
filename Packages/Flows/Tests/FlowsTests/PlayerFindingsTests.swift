import Core
import Foundation
import Testing

@testable import Flows

/// **The findings of the "Player" check** (2026-09-27) in the shared logic — they apply
/// equally on the TV and the phone; their checks show that it is wired in.
@MainActor
@Suite("Player: findings of the check, shared")
struct PlayerFindingsTests {

    // MARK: - S7: the board ends even without a title

    @Test("S7: If the title fails, loading ends, and the series' episodes still arrive")
    func boardWithoutTitleWithSeries() async {
        let catalog = ContentCatalog()  // titel == nil → item(id:) wirft
        catalog.episodes = [
            PlayerParityTests.title("f1", series: "s"), PlayerParityTests.title("f2", series: "s"),
        ]
        let board = InfoBoard()
        await board.load(
            source: catalog, identifier: "f1", series: "s", next: nil,
            mayPlay: PlayerParityTests.filter, applies: { true })
        #expect(board.loaded, "otherwise the board spins forever")
        #expect(board.isSeries)
        #expect(board.more.map(\.id) == ["f2"])
        #expect(!board.hasNothing)
    }

    @Test("S7: Without title and without series the board says nothing is there — and does not guess")
    func boardWithoutAnything() async {
        let catalog = ContentCatalog()
        catalog.similar = [PlayerParityTests.title("a")]
        let board = InfoBoard()
        await board.load(
            source: catalog, identifier: "provider-episode", series: nil, next: nil,
            mayPlay: PlayerParityTests.filter, applies: { true })
        #expect(board.loaded)
        #expect(board.more.isEmpty, "no \"Similar Movies\" under an episode without a title")
        #expect(board.hasNothing)
    }

    @Test("S7: After a failure the next look asks for the title again — afterwards not any more")
    func boardAfterFailure() async {
        let catalog = ContentCatalog()
        let board = InfoBoard()
        await board.load(
            source: catalog, identifier: "film", series: nil, next: nil,
            mayPlay: PlayerParityTests.filter, applies: { true })
        #expect(board.hasNothing)
        catalog.title = PlayerParityTests.title("film")
        await board.load(
            source: catalog, identifier: "film", series: nil, next: nil,
            mayPlay: PlayerParityTests.filter, applies: { true })
        #expect(board.title?.id == "film")
        catalog.title = PlayerParityTests.title("other")
        await board.load(
            source: catalog, identifier: "film", series: nil, next: nil,
            mayPlay: PlayerParityTests.filter, applies: { true })
        #expect(board.title?.id == "film", "loaded once is loaded")
    }

    @Test("S7: A cancellation of the view makes the next look ask again")
    func boardCancelled() async {
        let catalog = ContentCatalog()
        catalog.error = CancellationError()
        let board = InfoBoard()
        await board.load(
            source: catalog, identifier: "film", series: "s", next: nil,
            mayPlay: PlayerParityTests.filter, applies: { true })
        #expect(!board.loaded)
        #expect(!board.hasNothing)
    }

    // MARK: - S5 and S10: When the counter of the reports starts anew

    /// A core in the middle of a recording, signed in.
    private func signedIn() -> PlaybackCore {
        let core = PlaybackCoreTests.recording()
        _ = core.episode(status: .playing, location: 100, duration: 1_000)
        return core
    }

    @Test("S10: A rebuild on the same title does not sign in again")
    func rebuildKeepsReporter() {
        let core = signedIn()
        core.newTarget(reportsProgress: true, isRecording: true, sameTitle: true)
        #expect(core.episode(status: .playing, location: 500, duration: 1_000).report?.kind == .progress)
        #expect(core.finish(at: 500)?.kind == .stop, "and the sign-out belongs to the session")
    }

    @Test("S5: After a failure the same title signs in again")
    func afterFailureNewReporter() {
        let core = signedIn()
        #expect(core.episode(status: .failed, location: 120, duration: 1_000).report?.kind == .stop)
        core.newTarget(reportsProgress: true, isRecording: true, sameTitle: true)
        #expect(core.episode(status: .playing, location: 120, duration: 1_000).report?.kind == .start)
    }

    @Test("Another title always starts anew, a channel never signs in")
    func differentTitleNewReporter() {
        let core = signedIn()
        core.newTarget(reportsProgress: true, isRecording: true, sameTitle: false)
        #expect(core.episode(status: .playing, location: 0, duration: 1_000).report?.kind == .start)
        core.newTarget(reportsProgress: false, isRecording: false, sameTitle: true)
        #expect(core.episode(status: .playing, location: 10, duration: 0).report == nil)
    }

    // MARK: Fix round B (27.09.2026) — ultra finding e4 player, item 8

    /// **R8: A superseded failure of the series language does not throw the newer choice
    /// back** (remuxer check, finding 8, 2026-09-27).
    ///
    /// `select(_:)` sets the display immediately and reports afterwards — if the report
    /// fails, the display jumped back to the state BEFORE this call until the fix, even when
    /// a newer, successful choice has since taken effect. Two calls deliberately compete
    /// here: "en" hangs in the report, "tr" catches up and wins — only then does "en" fail.
    @Test("R8: An overtaken failure does not throw the newer choice back")
    func seriesLanguageSupersededFailureDoesNotRollBack() async throws {
        let gate = Gate()
        struct Failure: Error {}
        let routes = SeriesLanguageFlow.Routes(
            read: { "" },
            list: { [] },
            set: { language in
                if language == "en" {
                    await gate.wait()
                    throw Failure()
                }
            }
        )
        let flow = SeriesLanguageFlow(routes: routes)

        let first = Task { await flow.select("en") }
        // Wait until the first call has arrived and is hanging in `set` — the display shows
        // "en" before anything is stored.
        while flow.language != "en" { await Task.yield() }

        // A newer, successful choice overtakes the first call.
        await flow.select("tr")
        #expect(flow.language == "tr")

        // Only now does the superseded first call fail.
        await gate.approve()
        await first.value

        #expect(
            flow.language == "tr",
            "the overtaken failure of the first choice must not throw the second back")
    }
}

/// Lets a waiting caller continue on purpose — for R8: The superseded failure must only
/// strike AFTER the newer choice is already in place.
private actor Gate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func approve() {
        continuation?.resume()
        continuation = nil
    }
}
