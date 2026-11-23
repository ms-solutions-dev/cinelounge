import Foundation
import Testing
import WordingKit

@testable import SecondScreen

/// **One set of keys for both sides of the handoff, the clock under the code and the
/// service name** (AP58 R5, finding Z1).
@Suite("Handoff message, code clock, service name")
struct HandoffMessageTests {

    static let allErrors: [HandoffWire.TestError] = [
        .noService, .wasCancelled, .timedOut, .rejected(.accepted),
        .rejected(.expired), .rejected(.wrongVersion), .rejected(.unreadable),
    ]

    /// **Every case has a sentence on each side, and it is in `WordingKit`** — a missing one
    /// would appear on screen as a key name, and nothing would fail.
    @Test("Every rejection has a translated sentence on both sides", arguments: ["de", "en", "tr"])
    func everyRejectionHasASentence(language: String) {
        for page in [HandoffMessage.Page.channels, .receiver] {
            for error in Self.allErrors {
                let key = HandoffMessage.key(zu: error, page: page)
                let message = WordingKit.text(String.LocalizationValue(key), language: language)
                #expect(message != key, "\(key) missing in \(language)")
            }
        }
    }

    /// **The same refusal is different advice depending on the viewpoint** — and since 2026-09-26
    /// the TV distinguishes more than "cancelled".
    @Test("The sides say different things, and the TV knows more than one sentence")
    func sidesDiffer() {
        for error in Self.allErrors {
            #expect(
                HandoffMessage.key(zu: error, page: .channels)
                    != HandoffMessage.key(zu: error, page: .receiver))
        }
        let tv = Set(Self.allErrors.map { HandoffMessage.key(zu: $0, page: .receiver) })
        #expect(tv.count == 5)
    }

    // MARK: - Code clock

    /// **When the code expires, the clock reports it once and stops** — the screen then puts up
    /// a new one.
    @Test("The clock counts per tick and reports the expiry once")
    @MainActor
    func codeClock() async {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let key = HandoffKey.fresh(target: "probe", now: start)
        let pointer = Pointer(start)
        let clock = CodeClock(sleep: { _ in pointer.next(60) }, clock: { pointer.now })
        var ticks: [TimeInterval] = []
        var expired = 0
        clock.run(
            forItem: key, tick: { ticks.append($0) }, expired: { expired += 1 })
        await clock.run?.value
        #expect(ticks == [120, 60, 0])
        #expect(expired == 1)
    }

    @Test("If the screen no longer waits, the clock stops quietly")
    @MainActor
    func codeClockWhile() async {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let key = HandoffKey.fresh(target: "probe", now: start)
        let pointer = Pointer(start)
        let clock = CodeClock(sleep: { _ in pointer.next(60) }, clock: { pointer.now })
        var expired = 0
        clock.run(
            forItem: key, whileTrue: { false }, tick: { _ in }, expired: { expired += 1 })
        await clock.run?.value
        #expect(expired == 0)
    }

    // MARK: - Service name

    @Test("The handoff name carries four unambiguous characters")
    func serviceName() {
        let name = ServiceName.handoff()
        #expect(name.hasPrefix("CineLounge-"))
        let random = name.dropFirst("CineLounge-".count)
        #expect(random.count == 4)
        #expect(random.allSatisfy { ServiceName.character.contains($0) })
        #expect(!ServiceName.character.contains("0") && !ServiceName.character.contains("O"))
        #expect(!ServiceName.remote.isEmpty)
    }
}

/// A clock that only advances when the code clock is asleep.
private final class Pointer: @unchecked Sendable {
    private let lock = NSLock()
    private var state: Date
    init(_ start: Date) { state = start }
    var now: Date { lock.withLock { state } }
    func next(_ seconds: TimeInterval) { lock.withLock { state += seconds } }
}
