import CoreGraphics
import Testing

@testable import FeaturesPhone

/// **No feedback lies on a button** — in every orientation, on every device, at every
/// type size.
///
/// **The finding of 2026-09-25 (iPhone, portrait):** The time while scrubbing lay under the
/// pause button, the double-tap jump "10 s" on +30. In landscape it was not noticed; the
/// check therefore calculates both orientations and not only the one in which the error was found.
///
/// **The stages are rebuilt as ``PlayerView`` lays them:** the header at the top with a gap,
/// the bar at the bottom with a gap, the transport row (216 × 64) centered between the two — the
/// two `Spacer`s of the bar split evenly. The sizes of the messages are those measured on the
/// simulator, roughly doubled for the largest type size, and sentences wrap.
@Suite("Feedback slots")
struct FeedbackPlacementTests {

    /// A screen orientation: the safe area and how high header and bar currently are.
    struct Stage: CustomTestStringConvertible {
        let name: String
        let width: CGFloat
        let height: CGFloat
        let large: Bool

        var testDescription: String { name + (large ? ", largest text size" : "") }

        var surface: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }

        var buttons: FeedbackSlots.Buttons {
            let header = CGRect(x: 0, y: 12, width: width, height: large ? 96 : 44)
            let barHeight: CGFloat = large ? 96 : 64
            let bar = CGRect(
                x: 20, y: height - 12 - barHeight, width: width - 40, height: barHeight)
            let midpoint = (header.maxY + bar.minY) / 2
            let transport = CGRect(x: width / 2 - 108, y: midpoint - 32, width: 216, height: 64)
            return FeedbackSlots.Buttons(header: header, transport: transport, bar: bar)
        }

        /// How large a message becomes at this proposal — **like the real views.**
        ///
        /// An infinite height returns the natural size. A tighter height they accept
        /// until they have reached their tightest version (smaller type, fewer
        /// lines, the jump indicator without symbol); below that they stay that large and no
        /// longer fit — then the calculation does not place them.
        func measure(_ kind: Feedback, _ atMost: CGSize) -> CGSize {
            let naturalValue = natural(kind, atMost)
            guard atMost.height.isFinite,
                naturalValue.height > atMost.height || naturalValue.width > atMost.width
            else { return naturalValue }
            return CGSize(
                width: max(tightestWidth(kind) ?? naturalValue.width, min(naturalValue.width, atMost.width)),
                height: max(tightestHeight(kind), min(naturalValue.height, atMost.height)))
        }

        private func tightestWidth(_ kind: Feedback) -> CGFloat? {
            switch kind {
            case .skipBack, .skipForward: 40 * f + 24
            case .rate: 30 * f + 36
            case .pictureState: 80 * f
            case .stall, .hint, .time, .levelLeft, .levelRight: nil
            }
        }

        private var f: CGFloat { large ? 2.1 : 1 }

        private func natural(_ kind: Feedback, _ atMost: CGSize) -> CGSize {
            switch kind {
            case .stall: return message(width: 520 * f, row: 20 * f, atMost)
            case .hint: return message(width: 300 * f, row: 22 * f, atMost)
            case .time: return message(width: 150 * f, row: 22 * f, atMost)
            case .rate: return CGSize(width: 64 * f, height: 46 * f)
            case .pictureState: return CGSize(width: 150 * f, height: 34 * f)
            case .skipBack, .skipForward: return CGSize(width: 84 * f, height: 90 * f)
            case .levelLeft, .levelRight: return CGSize(width: 22 * f, height: 190 * f)
            }
        }

        private func tightestHeight(_ kind: Feedback) -> CGFloat {
            switch kind {
            case .stall: 10 * f + 8
            case .hint, .time, .rate: 11 * f + 24
            case .pictureState: 8 * f + 18
            case .skipBack, .skipForward: 11 * f + 12
            case .levelLeft, .levelRight: 84 + 15 * f
            }
        }

        /// A sentence in a capsule: 36 points of margin horizontally, 24 vertically.
        private func message(width: CGFloat, row: CGFloat, _ atMost: CGSize) -> CGSize {
            let inside = max(1, min(width, atMost.width - 36))
            let rows = (width / inside).rounded(.up)
            return CGSize(width: inside + 36, height: rows * row + 24)
        }

        func slots(_ shown: Set<Feedback>) -> [Feedback: CGRect] {
            FeedbackSlots.slots(
                shown: shown, surface: surface, buttons: buttons, measure: measure)
        }
    }

    static let devices: [(String, CGFloat, CGFloat)] = [
        ("iPhone SE portrait", 375, 647),
        ("iPhone SE landscape", 667, 375),
        ("iPhone 16 Pro portrait", 402, 778),
        ("iPhone 16 Pro landscape", 750, 381),
        ("iPhone 16 Pro Max portrait", 440, 862),
        ("iPad portrait", 1024, 1322),
        ("iPad landscape", 1366, 980),
    ]

    static let stages: [Stage] = devices.flatMap { name, width, height in
        [false, true].map { Stage(name: name, width: width, height: height, large: $0) }
    }

    /// The question at issue: **does anything lie on a button?**
    ///
    /// Individually and all at once — individually each message has its preferred place, at once
    /// the later ones must yield, and in yielding none may slide onto a button.
    @Test("No feedback overlaps a button", arguments: stages)
    func neverOnAButton(_ stage: Stage) {
        var cases = Feedback.allCases.map { Set([$0]) }
        cases.append(Set(Feedback.allCases))
        for shown in cases {
            for (kind, slot) in stage.slots(shown) {
                for button in stage.buttons.all {
                    #expect(
                        !slot.intersects(button),
                        "\(kind) sits on \(button) — slot \(slot), shown \(shown.count)")
                }
                #expect(stage.surface.contains(slot), "\(kind) sticks out of the surface: \(slot)")
            }
        }
    }

    /// What **really** can stand at once: board, short hint and picture position remain,
    /// plus the one gesture the finger is making right now. Two gestures
    /// at once do not exist — a finger does not scrub and double-tap.
    static let concurrently: [Set<Feedback>] = [
        .time, .skipBack, .skipForward, .levelLeft, .levelRight, .rate,
    ].map { Set([.stall, .hint, .pictureState, $0]) }

    /// **In ordinary type size each has its place**, and none lies on another.
    /// At the largest type size the space in landscape on the small iPhone does not suffice for four
    /// at once; there the more transient one drops (``Feedback/volatility``) — none
    /// lies on another, and none is drawn beyond its zone.
    @Test(
        "In regular text size every message has its slot, and none sits on another",
        arguments: stages.filter { !$0.large })
    func allPlaced(_ stage: Stage) {
        for shown in Self.concurrently {
            let slots = stage.slots(shown)
            #expect(slots.count == shown.count)
            let list = Array(slots)
            for i in list.indices {
                for j in list.indices where j > i {
                    #expect(
                        !list[i].value.intersects(list[j].value),
                        "\(list[i].key) and \(list[j].key) overlap")
                }
            }
        }
    }

    /// **Each individually has its place, even at the largest type size** — the ordinary
    /// case is one message at a time.
    @Test("Every message alone finds a slot, even in the largest text size", arguments: stages)
    func individuallyPlaced(_ stage: Stage) {
        for kind in Feedback.allCases {
            #expect(stage.slots([kind])[kind] != nil, "\(kind) has no slot")
        }
    }

    /// **The finding itself, in portrait:** The jump forward stands on the right and **above**
    /// +30, not on it; the jump back on the left above it.
    @Test("In portrait the skip sits above its side's button")
    func jumpPortrait() throws {
        let stage = Stage(name: "iPhone 16 Pro portrait", width: 402, height: 778, large: false)
        let row = stage.buttons.transport
        let forward = try #require(stage.slots([.skipForward])[.skipForward])
        #expect(forward.maxY <= row.minY)
        #expect(forward.minX >= row.midX)
        let back = try #require(stage.slots([.skipBack])[.skipBack])
        #expect(back.maxY <= row.minY)
        #expect(back.maxX <= row.midX)
    }

    /// **In landscape there is room beside the row**, and that is where the jump belongs — at the height of
    /// the buttons, on its side.
    @Test("In landscape the skip sits beside the row")
    func jumpLandscape() throws {
        let stage = Stage(name: "iPhone 16 Pro landscape", width: 750, height: 381, large: false)
        let row = stage.buttons.transport
        let forward = try #require(stage.slots([.skipForward])[.skipForward])
        #expect(forward.minX >= row.maxX)
        #expect(abs(forward.midY - row.midY) < 1)
        let back = try #require(stage.slots([.skipBack])[.skipBack])
        #expect(back.maxX <= row.minX)
    }

    /// **The time while scrubbing stands directly above the timeline** — no longer in the middle.
    @Test("The time while scrubbing sits above the timeline", arguments: stages.filter { !$0.large })
    func timeAboveBar(_ stage: Stage) throws {
        let time = try #require(stage.slots([.time])[.time])
        #expect(time.maxY <= stage.buttons.bar.minY)
        #expect(time.minY >= stage.buttons.transport.maxY)
    }

    /// **The board stands under the header**, where it is in nobody's way as long as it stays.
    @Test(
        "The stall board sits between header and transport row", arguments: stages.filter { !$0.large }
    )
    func boardBelowHeader(_ stage: Stage) throws {
        let board = try #require(stage.slots([.stall])[.stall])
        #expect(board.minY >= stage.buttons.header.maxY)
        #expect(board.maxY <= stage.buttons.transport.minY)
    }

    /// **Unmeasured, nothing stands in the middle.** Before the first measurement there are no
    /// buttons, but the middle stays with the pause button.
    @Test("Without a measurement the calculation avoids the center")
    func unmeasured() {
        let surface = CGRect(x: 0, y: 0, width: 402, height: 778)
        let slots = FeedbackSlots.slots(
            shown: Set(Feedback.allCases), surface: surface,
            buttons: .unmeasured(in: surface),
            measure: { _, _ in CGSize(width: 80, height: 40) })
        let midpoint = CGPoint(x: surface.midX, y: surface.midY)
        for (kind, slot) in slots {
            #expect(!slot.insetBy(dx: -1, dy: -1).contains(midpoint), "\(kind) sits on the center")
        }
    }
}
