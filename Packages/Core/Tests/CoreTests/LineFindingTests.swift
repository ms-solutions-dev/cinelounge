import Foundation
import Testing

@testable import Core

/// **Line against demand** (AP69, 2026-10-11) — the numbers from the probe: iptvhost delivered
/// 0.50 MB/s, the start of the episode needed 0.50 MB/s; the buffer grew 0.95 s per second.
@Suite("Line finding")
struct LineFindingTests {

    @Test("Line equal to demand is tight, 50 % headroom is not")
    func tight() {
        #expect(LineFinding(line: 500_000, demand: 500_000).tight)
        #expect(LineFinding(line: 550_000, demand: 500_000).tight)
        #expect(!LineFinding(line: 750_000, demand: 500_000).tight)
        #expect(!LineFinding(line: 500_000, demand: 0).tight)
    }

    @Test("Megabit with one decimal, German with a comma")
    func mbit() {
        let finding = LineFinding(line: 500_000, demand: 512_500)
        #expect(LineFinding.mbit(finding.lineMbit, locale: Locale(identifier: "de_DE")) == "4,0")
        #expect(LineFinding.mbit(finding.demandMbit, locale: Locale(identifier: "en_US")) == "4.1")
    }

    @Test("The probe of 11.10.: 20.7 MB for 41 s of film in 43 s — tight")
    func probe() {
        var meter = LineMeter()
        meter.take(.init(time: 12, deliveredBytes: 14_147, loadedSeconds: 0))
        #expect(meter.finding == nil)
        meter.take(.init(time: 14, deliveredBytes: 1_095_330, loadedSeconds: 2.3))
        let early = meter.finding
        #expect(early != nil)
        meter.take(.init(time: 55, deliveredBytes: 20_774_370, loadedSeconds: 41.0))
        let finding = meter.finding!
        #expect(abs(finding.line - 482_000) < 10_000, "\(finding.line)")
        #expect(abs(finding.demand - 506_000) < 10_000, "\(finding.demand)")
        #expect(finding.tight)
    }

    @Test("No finding below the window")
    func window() {
        var meter = LineMeter()
        meter.take(.init(time: 0, deliveredBytes: 0, loadedSeconds: 0))
        meter.take(.init(time: 1, deliveredBytes: 100_000, loadedSeconds: 1.9))
        #expect(meter.finding == nil)
        meter.take(.init(time: 3, deliveredBytes: 300_000, loadedSeconds: 2.5))
        #expect(meter.finding != nil)
    }

    @Test("A jump restarts the measurement")
    func jump() {
        var meter = LineMeter()
        meter.take(.init(time: 0, deliveredBytes: 50_000_000, loadedSeconds: 100))
        meter.take(.init(time: 3, deliveredBytes: 51_500_000, loadedSeconds: 103))
        #expect(meter.finding != nil)
        // Jumped back: fewer bytes, fewer seconds — everything before no longer counts.
        meter.take(.init(time: 4, deliveredBytes: 10_000_000, loadedSeconds: 20))
        #expect(meter.finding == nil)
        meter.take(.init(time: 7, deliveredBytes: 11_500_000, loadedSeconds: 23))
        #expect(meter.finding?.line == 500_000)
    }

    @Test("Good line: 10 Mbit/s for 4 Mbit/s is not tight")
    func good() {
        var meter = LineMeter()
        meter.take(.init(time: 0, deliveredBytes: 0, loadedSeconds: 0))
        meter.take(.init(time: 4, deliveredBytes: 5_000_000, loadedSeconds: 10))
        #expect(meter.finding?.tight == false)
    }
}
