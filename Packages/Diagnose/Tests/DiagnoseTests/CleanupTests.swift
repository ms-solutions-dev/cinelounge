import Foundation
import Testing

@testable import Diagnose

@Suite("Cleanup")
struct CleanupTests {

    private func entry(secondsAgo: TimeInterval, now: Date) -> ContentEntryRecord {
        ContentEntryRecord(
            timestamp: now.addingTimeInterval(-secondsAgo),
            area: .network, severity: .error, message: "x")
    }

    @Test("Entries that are too old are dropped")
    func alter() {
        let now = Date()
        let all = [
            entry(secondsAgo: 60, now: now),
            entry(secondsAgo: Cleanup.maxAge + 1, now: now),
        ]
        #expect(Cleanup.remains(all, now: now).count == 1)
    }

    @Test("Above the upper limit the newest remain")
    func upperLimit() {
        let now = Date()
        let all = (1...10).map { entry(secondsAgo: TimeInterval(10 - $0), now: now) }
        let remains = Cleanup.remains(all, now: now, maximumCount: 3)
        #expect(remains.count == 3)
        #expect(remains.last == all.last)
    }

    /// First the age, then the count — the other way around, a full week would throw away entries
    /// that the count rule would have kept.
    @Test("Age is applied before the count")
    func order() {
        let now = Date()
        let old = (1...5).map { _ in entry(secondsAgo: Cleanup.maxAge + 100, now: now) }
        let young = (1...2).map { _ in entry(secondsAgo: 5, now: now) }
        let remains = Cleanup.remains(old + young, now: now, maximumCount: 5)
        #expect(remains.count == 2)
    }

    @Test("An empty log stays empty")
    func empty() {
        #expect(Cleanup.remains([]).isEmpty)
    }
}
