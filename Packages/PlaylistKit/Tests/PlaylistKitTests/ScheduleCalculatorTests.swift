import Core
import Foundation
import Testing

@testable import PlaylistKit

/// The result cache of the schedule (E5) — tested against what it
/// is supposed to promise: **the first pass stays expensive, every further one is
/// free**, and it never lies.
///
/// What is counted for this is not time but how often the ingredients are fetched.
/// That is the question that matters: a hit must not cost even
/// one query to the database. A stopwatch would make the same
/// statement less sharply and would fall over on a busy machine.
@Suite("Schedule result store")
struct ScheduleCalculatorTests {

    private let kickoff = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func key(
        day: Int = 0, broadcasts: Int = 100, syncEnabled: Bool = true
    ) -> ScheduleCalculator.Key {
        ScheduleCalculator.Key(
            from: kickoff.addingTimeInterval(Double(day) * 86_400),
            end: kickoff.addingTimeInterval(Double(day) * 86_400 + 86_400),
            broadcasts: broadcasts,
            newest: kickoff,
            syncEnabled: syncEnabled)
    }

    private func ingredients(_ title: String) -> ScheduleCalculator.Ingredients {
        ScheduleCalculator.Ingredients(
            broadcasts: [
                Programme(
                    id: "p", channelID: "pusulasports1.tr", title: title, start: kickoff,
                    end: kickoff.addingTimeInterval(7200))
            ],
            channelNames: ["pusulasports1.tr": "Pusula SPORTS 1"],
            fixtures: [],
            channels: [], observations: [])
    }

    /// A counter that reads along from outside how often the ingredients were fetched.
    private actor TallyCounter {
        private(set) var state = 0
        func up() { state += 1 }
    }

    @Test("The second pass costs nothing — and yields the same")
    func secondPassIsFree() async {
        let calculator = ScheduleCalculator()
        let counter = TallyCounter()
        let fetch: @Sendable () async -> ScheduleCalculator.Ingredients = {
            await counter.up()
            return self.ingredients("Kalesaray - Dalgaspor")
        }

        let first = await calculator.events(key(), ingredients: fetch)
        let second = await calculator.events(key(), ingredients: fetch)

        #expect(first.count == 1)
        #expect(first == second)
        #expect(await counter.state == 1)
    }

    @Test("Another day is another computation")
    func otherDayRecalculates() async {
        let calculator = ScheduleCalculator()
        let counter = TallyCounter()
        let fetch: @Sendable () async -> ScheduleCalculator.Ingredients = {
            await counter.up()
            return self.ingredients("Kalesaray - Dalgaspor")
        }

        _ = await calculator.events(key(day: 0), ingredients: fetch)
        _ = await calculator.events(key(day: 1), ingredients: fetch)
        // And back to the first tab: it is still there.
        _ = await calculator.events(key(day: 0), ingredients: fetch)

        #expect(await counter.state == 2)
    }

    /// **The case that makes a result cache dangerous.** When
    /// programme arrives, the answer has to be recalculated — otherwise the
    /// area would, after a sync, keep showing the empty schedule from before, and
    /// nobody would know why the button did nothing.
    @Test("A changed cache state invalidates the stored answer")
    func newDownloadsStateRecalculates() async {
        let calculator = ScheduleCalculator()
        let counter = TallyCounter()
        let fetch: @Sendable () async -> ScheduleCalculator.Ingredients = {
            await counter.up()
            return self.ingredients("Kalesaray - Dalgaspor")
        }

        _ = await calculator.events(key(broadcasts: 100), ingredients: fetch)
        _ = await calculator.events(key(broadcasts: 101), ingredients: fetch)
        #expect(await counter.state == 2)

        // And the sync switch likewise: it changes the list without
        // a programme moving.
        _ = await calculator.events(key(syncEnabled: false), ingredients: fetch)
        #expect(await counter.state == 3)
    }

    @Test("What is not in the key is discarded by hand")
    func clearingRecalculates() async {
        let calculator = ScheduleCalculator()
        let counter = TallyCounter()
        let fetch: @Sendable () async -> ScheduleCalculator.Ingredients = {
            await counter.up()
            return self.ingredients("Kalesaray - Dalgaspor")
        }

        _ = await calculator.events(key(), ingredients: fetch)
        await calculator.clear()
        _ = await calculator.events(key(), ingredients: fetch)

        #expect(await counter.state == 2)
    }

    /// The cache must not grow. Five states, four slots — the oldest
    /// must give way and be recalculated the next time.
    @Test("The store holds four answers, no more")
    func memoryDoesNotGrow() async {
        let calculator = ScheduleCalculator()
        let counter = TallyCounter()
        let fetch: @Sendable () async -> ScheduleCalculator.Ingredients = {
            await counter.up()
            return self.ingredients("Kalesaray - Dalgaspor")
        }

        for state in 0..<ScheduleCalculator.atMost + 1 {
            _ = await calculator.events(key(broadcasts: state), ingredients: fetch)
        }
        #expect(await counter.state == ScheduleCalculator.atMost + 1)

        // The most recently stored one is still there …
        _ = await calculator.events(
            key(broadcasts: ScheduleCalculator.atMost), ingredients: fetch)
        #expect(await counter.state == ScheduleCalculator.atMost + 1)
        // … the first one is not.
        _ = await calculator.events(key(broadcasts: 0), ingredients: fetch)
        #expect(await counter.state == ScheduleCalculator.atMost + 2)
    }

    /// A gate that stops the calculation until the test waves it on.
    ///
    /// Without such a thing, "during the calculation" could be reproduced only with a wait time,
    /// and a test that waits for a clock turns red for no reason on a
    /// busy machine.
    private actor Checkpoint {
        private var pending = false
        /// How many calculations have reached the gate so far.
        private(set) var arrived = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []

        /// Called by the calculation: registers and holds until the gate is opened.
        func wait() async {
            arrived += 1
            guard !pending else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            pending = true
            for continuation in waiters { continuation.resume() }
            waiters.removeAll()
        }
    }

    /// Waits until this many calculations stand at the gate — **with an upper limit**.
    ///
    /// The limit is no ornament but the result of an experiment on
    /// 2026-08-29: whoever attaches to a discarded calculation never
    /// arrives at the gate. A test that waits for that without a limit **hangs** on a
    /// regression instead of turning red — and `.timeLimit` does not solve
    /// this, because a blocked continuation does not notice a cancellation (the run
    /// was still stuck after ten minutes). One second is plenty for two
    /// milliseconds of work; if it is exceeded, the expectation behind it
    /// fails.
    private func untilArrived(_ count: Int, on gate: Checkpoint) async {
        for _ in 0..<200 {
            if await gate.arrived >= count { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// **The finding of the acceptance review of 2026-08-29** A ``ScheduleCalculator/clear()``
    /// during a running calculation had no effect: the stored result was
    /// cleared, but the calculation alongside then stored its answer anyway —
    /// calculated from ingredients from before the clearing.
    ///
    /// That would have hit exactly the case ``ScheduleCalculator/clear()``
    /// exists for: the one the key does not notice. Whoever presses refresh in the open
    /// area while the first pass is still calculating
    /// (in device size 3,4 s — plenty of time for that), and gets the same
    /// guide back with corrected titles, moves neither count
    /// nor reach. The key would stay the same, and the answer just discarded
    /// would be there again afterwards.
    @Test("A clear during the computation does not store the old answer after all")
    func clearingDuringCalculation() async {
        let calculator = ScheduleCalculator()
        let counter = TallyCounter()
        let gate = Checkpoint()
        let fetch: @Sendable () async -> ScheduleCalculator.Ingredients = {
            await counter.up()
            await gate.wait()
            return self.ingredients("Kalesaray - Dalgaspor")
        }

        let first = Task { await calculator.events(self.key(), ingredients: fetch) }
        await untilArrived(1, on: gate)
        await calculator.clear()
        await gate.open()
        #expect(await first.value.count == 1)

        // The same key — the download store has changed in a way
        // it does not see. It MUST be calculated once more anyway.
        #expect(await calculator.events(key(), ingredients: fetch).count == 1)
        #expect(await counter.state == 2)
    }

    /// And whoever asks the same question after clearing must not attach
    /// to the running calculation from before: it calculates on the ingredients
    /// that were just discarded.
    @Test("Whoever asks after the clear does not attach to the old computation")
    func followerAfterClearingCalculatesItself() async {
        let calculator = ScheduleCalculator()
        let counter = TallyCounter()
        let gate = Checkpoint()
        let fetch: @Sendable () async -> ScheduleCalculator.Ingredients = {
            await counter.up()
            await gate.wait()
            return self.ingredients("Kalesaray - Dalgaspor")
        }

        let first = Task { await calculator.events(self.key(), ingredients: fetch) }
        await untilArrived(1, on: gate)
        await calculator.clear()

        // The same key, and the old calculation is still at the gate. The
        // second asker must start its own anyway — otherwise it would get
        // the result of the discarded ingredients.
        let second = Task { await calculator.events(self.key(), ingredients: fetch) }
        await untilArrived(2, on: gate)
        #expect(await counter.state == 2)

        await gate.open()
        #expect(await first.value.count == 1)
        #expect(await second.value.count == 1)
    }

    /// The rules stayed unchanged in the move out of ``LiveLibrary`` —
    /// the same chain, only in a different place. Tested at the spot where
    /// a move is most likely to lose something: evidence beats advice.
    @Test("Moving out of the actor did not touch the rules")
    func rulesUnchanged() {
        let broadcasts = [
            Programme(
                id: "p1", channelID: "pusulasports1.tr", title: "Kalesaray - Dalgaspor",
                start: kickoff, end: kickoff.addingTimeInterval(7200)),
            Programme(
                id: "p2", channelID: "kafesspor.tr", title: "Boks: Kalberg - Serrat",
                start: kickoff, end: kickoff.addingTimeInterval(7200)),
        ]
        let fixture = SportFixture(
            id: "1", kind: .football, league: "Süper Lig", home: "Kalesaray",
            away: "Dalgaspor", start: kickoff)

        let withoutFixtures = ScheduleCalculator.calculate(
            ScheduleCalculator.Ingredients(
                broadcasts: broadcasts, channelNames: ["pusulasports1.tr": "Pusula SPORTS 1"],
                fixtures: [], channels: [], observations: []))
        #expect(withoutFixtures.count == 2)
        #expect(withoutFixtures.allSatisfy { !$0.isVerified })

        let withFixture = ScheduleCalculator.calculate(
            ScheduleCalculator.Ingredients(
                broadcasts: broadcasts, channelNames: ["pusulasports1.tr": "Pusula SPORTS 1"],
                fixtures: [fixture], channels: [], observations: []))
        #expect(withFixture.count == 2)
        // The evidenced event has displaced the guessed twin; the
        // boxing match without a fixture stands beside it as a supplement.
        #expect(withFixture.filter(\.isVerified).count == 1)
        #expect(withFixture.first(where: \.isVerified)?.competition == "Süper Lig")
    }
}
