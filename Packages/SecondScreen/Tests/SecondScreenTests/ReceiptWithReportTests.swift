import Foundation
import Testing

@testable import SecondScreen

/// **The receipt carries what has arrived** — AP39, 2026-09-20.
///
/// The finding of 2026-09-19: a `UInt8` with four cases went back. The TV knows that it
/// **rejected** the parental controls (the device already has its own), shows it on its
/// screen — and the sender on the phone could never learn it. Exactly this line is the more
/// important one: what has *not* arrived and why.
@Suite("The receipt carries a report")
struct ReceiptWithReportTests {

    private func report() -> Takeover.Report {
        var report = Takeover.Report()
        report.jellyfin = "media.example"
        report.channelLists = 3
        report.bridge = true
        report.key = 2
        report.parentalControls = false
        report.parentalControlsRejected = true
        report.language = "de"
        return report
    }

    @Test("The report survives the round trip — including the line that never existed before")
    func reportSurvivesTheRound() throws {
        let data = try JSONEncoder().encode(report())
        let back = try JSONDecoder().decode(Takeover.Report.self, from: data)

        #expect(back == report())
        #expect(back.parentalControlsRejected)
    }

    @Test("Behind the receipt byte there is a readable frame")
    func byteThenFrame() throws {
        // Exactly the shape that ``HandoffReceiver`` sends out: one byte as always, then the
        // framed report.
        var outbound = Data([HandoffWire.Receipt.accepted.rawValue])
        outbound.append(HandoffWire.Frame.pack(try JSONEncoder().encode(report())))

        // And exactly this is how the other side reads: first one byte, then four bytes of length.
        let receipt = HandoffWire.Receipt(rawValue: outbound.removeFirst())
        #expect(receipt == .accepted)

        let length = try #require(HandoffWire.Frame.length(from: outbound))
        let bodyContent = outbound.dropFirst(4).prefix(length)
        #expect(bodyContent.count == length)

        let read = try JSONDecoder().decode(Takeover.Report.self, from: Data(bodyContent))
        #expect(read == report())
    }

    @Test("A TV without a report remains a valid peer")
    func onlyTheByte() {
        // The version before 2026-09-20 sends exactly one byte and hangs up. For the other side that
        // means "accepted, nothing to report" — and **not** "handoff failed". That is the whole
        // reason why the report is appended at the end and was not built into the byte.
        var byteOnly = Data([HandoffWire.Receipt.accepted.rawValue])

        #expect(HandoffWire.Receipt(rawValue: byteOnly.removeFirst()) == .accepted)
        #expect(byteOnly.isEmpty)
        #expect(HandoffWire.Frame.length(from: byteOnly) == nil)
    }
}
