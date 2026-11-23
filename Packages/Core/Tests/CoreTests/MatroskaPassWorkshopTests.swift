import Foundation
import Testing

@testable import Core

/// **F-025 (2026-09-28):** The walk through a truncated file takes minutes; whoever
/// went back before threw it away.
@Suite("The pass through the clusters does not belong to the player")
struct MatroskaPassWorkshopTests {

    final class TallyCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        private var stored = 0
        func work() { lock.withLock { n += 1 } }
        func store() { lock.withLock { stored += 1 } }
        var runs: Int { lock.withLock { n } }
        var stores: Int { lock.withLock { stored } }
    }

    private static let header = MatroskaClusterWalk.ClusterHead(
        position: 100, end: 200, time: 0, startsWithKeyframe: true)

    /// A gate that holds the work until the test opens it. **No clock in the test**
    /// (full check run, 2026-10-11): With "wait 50 ms, then cancel, work takes 300 ms"
    /// the walk was already finished under load before the cancellation came — the test measured the
    /// load of the Mac, not the workshop.
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var pending = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func open() {
            let w: [CheckedContinuation<Void, Never>] = lock.withLock {
                pending = true
                defer { waiters = [] }
                return waiters
            }
            w.forEach { $0.resume() }
        }
        func wait() async {
            await withCheckedContinuation { continuation in
                let immediately: Bool = lock.withLock {
                    if pending { return true }
                    waiters.append(continuation)
                    return false
                }
                if immediately { continuation.resume() }
            }
        }
    }

    @Test("A cancelled caller lets the pass run to the end and persist")
    func survivesCancellation() async throws {
        let counter = TallyCounter()
        let gate = Gate()
        let key = "probe-\(UUID().uuidString)"
        let caller = Task {
            try await MatroskaGearWorkshop.run(
                key: key,
                work: {
                    counter.work()
                    await gate.wait()
                    return [Self.header]
                },
                persist: { _ in counter.store() })
        }
        caller.cancel()
        let outcome = await caller.result
        #expect(throws: CancellationError.self) { try outcome.get() }
        #expect(counter.stores == 0, "the caller returns immediately, the pass is still running")

        gate.open()
        for _ in 0..<500 where counter.stores == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(counter.stores == 1, "persisted although nobody was waiting any more")
        #expect(counter.runs == 1)
    }

    @Test("A second attempt attaches to the running pass")
    func onePassPerFile() async throws {
        let counter = TallyCounter()
        let key = "probe-\(UUID().uuidString)"
        let pass: @Sendable () async throws -> MatroskaGearWorkshop.Outcome = {
            try await MatroskaGearWorkshop.run(
                key: key,
                work: {
                    counter.work()
                    try? await Task.sleep(for: .milliseconds(200))
                    return [Self.header]
                },
                persist: { _ in counter.store() })
        }
        async let first = pass()
        async let second = pass()
        let (a, b) = try await (first, second)
        #expect(a.heads == b.heads)
        #expect(counter.runs == 1)
        #expect(counter.stores == 1)
    }

    /// **F-002:** Wolf ran to completion in the background, and Solo queued behind it. Two walks
    /// at once shared the line and the disk.
    @Test("Two passes for different files run one after another")
    func oneAfterAnother() async throws {
        final class Trace: @unchecked Sendable {
            private let lock = NSLock()
            private var events: [String] = []
            func note(_ e: String) { lock.withLock { events.append(e) } }
            var all: [String] { lock.withLock { events } }
        }
        let trace = Trace()
        func pass(_ name: String) async throws -> MatroskaGearWorkshop.Outcome {
            try await MatroskaGearWorkshop.run(
                key: "probe-\(name)-\(UUID().uuidString)",
                work: {
                    trace.note("\(name) on")
                    try? await Task.sleep(for: .milliseconds(150))
                    trace.note("\(name) off")
                    return [Self.header]
                },
                persist: { _ in })
        }
        async let a = pass("a")
        try await Task.sleep(for: .milliseconds(20))
        async let b = pass("b")
        _ = try await (a, b)
        #expect(trace.all == ["a on", "a off", "b on", "b off"])
    }
}
