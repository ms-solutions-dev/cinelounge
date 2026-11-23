import CoreGraphics
import Foundation
import SourceProbe
import SwiftUI
import Testing

@testable import FeaturesPhone

/// **The counter-check of the player of 2026-09-25** — findings B1 to B6.
///
/// * **B1:** With large type, messages drew beyond their zone; the fallback
///   only shortened the rectangle, the board with `fixedSize` did not accept the proposal at all.
/// * **B2:** The fallback placed with `beside: []` and stacked messages on top of each other.
/// * **B3:** A cancelled gesture left preview, level, pull and speed standing.
/// * **B4/B5:** The bar went away after four seconds despite the board, and a grab did not reset
///   the clock.
/// * **B6:** VoiceOver did not announce the board and read out messages that were not placed.
@Suite("Player · feedback and gestures")
struct PlayerFeedbackTests {

    typealias Stage = FeedbackPlacementTests.Stage

    // MARK: - B1: gezeichnet wird in der Zone

    /// **Drawing uses the slot's proposal** — exactly how the
    /// ``FeedbackStage`` lays out its children. What comes out must fit the slot and
    /// thereby stay clear of every button.
    @Test(
        "The drawn size stays in its slot and clear of the buttons",
        arguments: FeedbackPlacementTests.stages)
    func drawnInPlace(_ stage: Stage) {
        let cases = FeedbackPlacementTests.concurrently + Feedback.allCases.map { Set([$0]) }
        for shown in cases {
            for (kind, slot) in stage.slots(shown) {
                let drawn = stage.measure(kind, slot.size)
                #expect(
                    FeedbackSlots.matches(drawn, in: slot),
                    "\(kind) draws \(drawn) in \(slot)")
                let frame = CGRect(origin: slot.origin, size: drawn)
                for button in stage.buttons.all {
                    #expect(!frame.intersects(button), "\(kind) \(frame) overlaps \(button)")
                }
            }
        }
    }

    // MARK: - B2: keine Meldung auf einer anderen

    private static func overlaps(_ slots: [Feedback: CGRect]) -> [String] {
        let list = Array(slots)
        var discoveries: [String] = []
        for i in list.indices {
            for j in list.indices where j > i && list[i].value.intersects(list[j].value) {
                discoveries.append("\(list[i].key) \(list[i].value) / \(list[j].key) \(list[j].value)")
            }
        }
        return discoveries
    }

    @Test(
        "No message on top of another, even at the largest type size",
        arguments: FeedbackPlacementTests.stages)
    func noOverlap(_ stage: Stage) {
        for shown in FeedbackPlacementTests.concurrently {
            #expect(Self.overlaps(stage.slots(shown)).isEmpty)
        }
    }

    /// **The device keys arrive independently of the finger** — the volume bar can stand next to
    /// any gesture.
    @Test("Device buttons during a gesture", arguments: FeedbackPlacementTests.stages)
    func buttonLevelBesideGesture(_ stage: Stage) {
        let gestures: [Feedback] = [.time, .skipBack, .skipForward, .rate, .levelLeft]
        for gesture in gestures {
            let shown: Set<Feedback> = [.stall, .hint, .pictureState, .levelRight, gesture]
            #expect(Self.overlaps(stage.slots(shown)).isEmpty, "\(gesture)")
        }
    }

    @Test("All pairs and triples sit side by side", arguments: FeedbackPlacementTests.stages)
    func pairsAndTriples(_ stage: Stage) {
        let all = Feedback.allCases
        var sets: [Set<Feedback>] = []
        for a in all.indices {
            for b in all.indices where b > a {
                sets.append([all[a], all[b]])
                for c in all.indices where c > b { sets.append([all[a], all[b], all[c]]) }
            }
        }
        for shown in sets {
            #expect(Self.overlaps(stage.slots(shown)).isEmpty)
        }
    }

    /// **The one that has to yield is the more fleeting one.** Without free space the gesture drops out and
    /// not the board.
    @Test("Without space the more transient message drops out")
    func transientYields() {
        let surface = CGRect(x: 0, y: 0, width: 300, height: 300)
        let buttons = FeedbackSlots.Buttons(
            header: CGRect(x: 0, y: 0, width: 300, height: 20),
            transport: CGRect(x: 0, y: 140, width: 300, height: 20),
            bar: CGRect(x: 0, y: 280, width: 300, height: 20))
        let slots = FeedbackSlots.slots(
            shown: [.stall, .hint, .rate], surface: surface, buttons: buttons,
            measure: { _, _ in CGSize(width: 250, height: 90) })
        #expect(slots[.stall] != nil)
        #expect(slots[.hint] != nil)
        #expect(slots[.rate] == nil)
        #expect(Self.overlaps(slots).isEmpty)
    }

    // MARK: - B1: die echten Ansichten nehmen den Vorschlag an

    #if canImport(AppKit)
        /// Measures a real view with a tight proposal — **the way the stage measures.**
        private struct MeasuringStage: Layout {
            let suggestion: ProposedViewSize
            let result: Store
            final class Store: @unchecked Sendable { var size: CGSize = .zero }

            func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
                result.size = subviews.first?.sizeThatFits(suggestion) ?? .zero
                return proposal.replacingUnspecifiedDimensions()
            }

            func placeSubviews(
                in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
            ) {
                for view in subviews { view.place(at: bounds.origin, proposal: suggestion) }
            }
        }

        @MainActor
        private static func measured(_ view: some View, _ suggestion: CGSize) -> CGSize {
            let store = MeasuringStage.Store()
            let root = MeasuringStage(suggestion: ProposedViewSize(suggestion), result: store) {
                view
            }
            .frame(width: 800, height: 600)
            let carrier = NSHostingView(rootView: root)
            carrier.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
            carrier.layoutSubtreeIfNeeded()
            return store.size
        }

        @Test("The stillness board keeps to a tight height")
        @MainActor
        func boardClamps() {
            let suggestion = CGSize(width: 110, height: 40)
            let size = Self.measured(StallBoard(finding: .sourceSilent), suggestion)
            #expect(size.height <= suggestion.height + 0.5, "\(size)")
            #expect(size.width <= suggestion.width + 0.5, "\(size)")
        }

        @Test("The skip indicator keeps to a tight height — without icon")
        @MainActor
        func skipClamps() {
            let suggestion = CGSize(width: 90, height: 40)
            let state = JumpIndicator.State(forward: true, seconds: 30)
            let size = Self.measured(JumpIndicator(state: state), suggestion)
            #expect(size.height <= suggestion.height + 0.5, "\(size)")
        }

        @Test("The seek-time capsule keeps to a tight height")
        @MainActor
        func capsuleClamps() {
            let suggestion = CGSize(width: 120, height: 40)
            let wording = "1:23:45  " + SwipeZones.distanceText(-70)
            let size = Self.measured(HintCapsule(wording: wording), suggestion)
            #expect(size.height <= suggestion.height + 0.5, "\(size)")
        }
    #endif

    // MARK: - Quelltext

    private static func code(_ name: String) throws -> String {
        try SourceText.read(name, in: .featuresPhone)
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    @Test("The stage lays out only what fits its proposal and reports the rest")
    func stageChecksDrawn() throws {
        let stage = try Self.code("FeedbackStage.swift")
        #expect(stage.contains("sizeThatFits(ProposedViewSize(slot.size))"))
        #expect(stage.contains("state.notify(unplaced)"))
        let board = try Self.code("StallBoard.swift")
        #expect(!board.contains("fixedSize"), "the board accepts the proposal")
    }

    // MARK: - B3: abgebrochene Gesten

    @Test("A cancel takes everything back — without seeking and without ending")
    func cancelTakesBack() {
        #expect(
            SwipeZones.cancelSteps(lookahead: true, level: true, drag: 0.8, vertical: true, fast: true)
                == [.discardPreview, .snapBack, .releaseAnchor, .hideLevel, .speedBack])
        #expect(
            SwipeZones.cancelSteps(
                lookahead: false, level: false, drag: 0, vertical: false, fast: false
            )
            .isEmpty)
        #expect(
            SwipeZones.cancelSteps(lookahead: false, level: false, drag: 0, vertical: false, fast: true)
                == [.speedBack], "double speed never stays on")
    }

    @Test("Scene change and disappearing cancel the gesture")
    func cancelIsWired() throws {
        let zones = try Self.code("SwipeZones.swift")
        #expect(zones.contains(".onChange(of: scenePhase)"))
        #expect(zones.contains(".onDisappear { cancel() }"))
        #expect(zones.contains("if fresh != .active { cancel() }"))
    }

    // MARK: - B4/B5: die Uhr der Leiste

    @Test("While the board is up, the clock does not hide the bar")
    func watchHoldsAtBoard() {
        #expect(BarClock.fadesOut(isVisible: true, isRunning: true, settled: false))
        #expect(!BarClock.fadesOut(isVisible: true, isRunning: true, settled: true))
        #expect(!BarClock.fadesOut(isVisible: true, isRunning: false, settled: false))
        #expect(!BarClock.fadesOut(isVisible: false, isRunning: true, settled: false))
        #expect(
            BarClock(isVisible: true, settled: false, touches: 1)
                != BarClock(isVisible: true, settled: false, touches: 2),
            "every grip is a new identity")
    }

    @Test("The clock restarts with the board and the grip")
    @MainActor
    func watchIsWired() throws {
        let view = try Self.code("SpielerView.swift")
        #expect(
            view.contains("isVisible: model.isBarVisible, settled: model.settled, touches: touches")
        )
        #expect(!view.contains(".task(id: model.leisteSichtbar)"))
        let fresh = ChildProfilePhoneTests.bodyContent("private func restartClock(", in: view)
        #expect(fresh.contains("touches += 1"))
        let running = ChildProfilePhoneTests.bodyContent("private func runClock(", in: view)
        #expect(running.contains("settled: model.settled"))
    }

    // MARK: - B6: Vorlesehilfe

    @Test("The board is announced, and what is not laid out is hidden")
    func voiceOverActive() throws {
        let view = try Self.code("SpielerView.swift")
        #expect(view.contains("AccessibilityNotification.Announcement("))
        #expect(view.contains("StallWording.key(model.stallFinding)"))
        #expect(!view.contains(".feedback(.stillstand)\n"))
        let notifications = view.ranges(of: ".feedback(").map { view[$0.lowerBound...].prefix(90) }
        #expect(notifications.count == 7)
        #expect(notifications.allSatisfy { $0.contains("state: feedbackLayout") })
        let stage = try Self.code("FeedbackStage.swift")
        #expect(stage.contains("accessibilityHidden(state.unplaced.contains(kind))"))
    }
}
