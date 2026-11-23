import Foundation
import Testing

@testable import Core

/// The breakdown of the startup — the calculation of where the time went (AP7 · 1).
@Suite("The startup breakdown")
struct StartupMarksTests {

    @Test("Four sections, in milliseconds, in startup order")
    func fourSections() {
        let start = Date(timeIntervalSince1970: 1000)
        var marks = StartupMarks()
        marks.connected = start
        marks.firstData = start.addingTimeInterval(0.61)
        marks.firstKeyframe = start.addingTimeInterval(0.65)
        marks.downloadsReady = start.addingTimeInterval(0.88)
        let end = start.addingTimeInterval(1.12)
        #expect(
            marks.breakdown(start: start, end: end)
                == "Provider 610 · Keyframe 40 · Buffer 230 · Player 240")
    }

    @Test("A warm address is included, missing marks drop out")
    func warmAndMissing() {
        let start = Date(timeIntervalSince1970: 1000)
        var marks = StartupMarks()
        marks.warmAddress = true
        marks.firstData = start.addingTimeInterval(0.12)
        marks.downloadsReady = start.addingTimeInterval(0.40)
        let end = start.addingTimeInterval(0.60)
        #expect(marks.breakdown(start: start, end: end) == "Provider 120 (warm) · Buffer 280 · Player 200")
    }

    @Test("The startup line carries the breakdown when a remuxer was involved")
    func timingLineCarriesBreakdown() {
        let start = Date(timeIntervalSince1970: 1000)
        var timing = StartupTiming(opening: "native/remuxInApp", startedAt: start)
        var marks = StartupMarks()
        marks.firstData = start.addingTimeInterval(0.5)
        marks.downloadsReady = start.addingTimeInterval(0.8)
        timing.remux = marks
        timing.markReady(at: start.addingTimeInterval(1.0))
        timing.markFirstFrame(at: start.addingTimeInterval(1.1))
        #expect(timing.line.hasSuffix("  = Provider 500 · Buffer 300 · Player 300"))
        // Without the repackager the line stays as it was.
        var without = StartupTiming(opening: "native/directPlay", startedAt: start)
        without.markFirstFrame(at: start.addingTimeInterval(0.2))
        #expect(!without.line.contains(" = "))
    }
}

/// The warm addresses — remembered, expire, forgotten (AP7 · 2).
@Suite("Warm addresses")
struct EdgeMemoryTests {
    private let panel = URL(string: "http://panel.example/live/u/p/1.ts")!
    private let edge = URL(string: "http://edge3.example:80/x/token/1.ts")!

    @Test("The redirect is remembered, and it holds for a while")
    func rememberAndRecall() {
        let memory = EdgeMemory()
        let now = Date()
        #expect(memory.edge(for: panel, now: now) == nil)
        memory.remember(source: panel, edge: edge, at: now)
        #expect(memory.edge(for: panel, now: now.addingTimeInterval(60)) == edge)
        #expect(memory.edge(for: panel, now: now.addingTimeInterval(EdgeMemory.lifetime + 1)) == nil)
        #expect(memory.count == 0, "expired means gone")
    }

    @Test("Forgotten is forgotten, and an address pointing to itself does not count")
    func forgetAndSelf() {
        let memory = EdgeMemory()
        memory.remember(source: panel, edge: edge)
        memory.forget(source: panel)
        #expect(memory.edge(for: panel) == nil)
        memory.remember(source: panel, edge: panel)
        #expect(memory.count == 0)
    }
}

/// A provider whose edge rejects the warm address gets none any more.
@Suite("Warm addresses · rejection per provider")
struct EdgeMemoryRejectionTests {
    @Test("After a rejection the store remembers the provider")
    func rejectionSticksToHost() {
        let memory = EdgeMemory()
        let a = URL(string: "http://panel.example/live/u/p/1.ts")!
        let b = URL(string: "http://panel.example/live/u/p/2.ts")!
        let other = URL(string: "http://andere.example/live/u/p/1.ts")!
        let edge = URL(string: "http://edge.example/x/1.ts")!
        memory.remember(source: a, edge: edge)
        memory.rejectWarm(source: a)
        #expect(memory.edge(for: a) == nil)
        #expect(!memory.allowsWarm(source: b))
        memory.remember(source: b, edge: edge)
        #expect(memory.edge(for: b) == nil, "the same provider no longer gets a warm address")
        memory.remember(source: other, edge: edge)
        #expect(memory.edge(for: other) == edge, "another provider still does")
    }
}
