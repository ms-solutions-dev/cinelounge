import Observation
import SwiftUI

/// The area on which all of the player's feedback appears — **one stack for all.**
///
/// **Why a `Layout` of its own and not overlays with alignment.** Until 2026-09-25 every
/// message hung where it arose: the time and the jump at the swipe surface, the short hint
/// and the picture layout at the controls. Each calculated its location by itself, and
/// none knew the buttons — the time lay under the pause button, the jump on +30. Here all
/// get their place from the same calculation (``FeedbackSlots``), and that knows the
/// measured buttons.
///
/// **Measurement happens with the space the zone offers.** A sentence in a narrow zone
/// wraps instead of running over its edge; only a `Layout` can do that, because only it
/// may make each view its own proposal before it places it.
struct FeedbackStage: Layout {

    /// The measured rows — `nil` as long as none has been measured.
    let buttons: FeedbackSlots.Buttons?
    /// Where the stage reports what it has **not** placed — for the screen reader.
    let state: FeedbackLayout

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let surface = CGRect(origin: .zero, size: bounds.size)
        var byKind: [Feedback: LayoutSubview] = [:]
        for view in subviews {
            if let kind = view[FeedbackKind.self] { byKind[kind] = view }
        }
        let slots = FeedbackSlots.slots(
            shown: Set(byKind.keys), surface: surface,
            buttons: buttons ?? .unmeasured(in: surface),
            measure: { kind, atMost in
                byKind[kind]?.sizeThatFits(
                    ProposedViewSize(
                        width: atMost.width,
                        height: atMost.height.isFinite ? atMost.height : nil))
                    ?? .zero
            })
        var unplaced: Set<Feedback> = []
        for (kind, view) in byKind {
            guard let slot = slots[kind],
                FeedbackSlots.matches(
                    view.sizeThatFits(ProposedViewSize(slot.size)), in: slot)
            else {
                unplaced.insert(kind)
                // **Out of the zone, not into the middle.** SwiftUI would put an unplaced child in the
                // middle of the area — exactly on the pause button.
                view.place(
                    at: CGPoint(x: bounds.minX, y: bounds.maxY + 10_000), proposal: .zero)
                continue
            }
            view.place(
                at: CGPoint(x: bounds.minX + slot.minX, y: bounds.minY + slot.minY),
                anchor: .topLeading, proposal: ProposedViewSize(slot.size))
        }
        state.notify(unplaced)
    }
}

/// What the ``FeedbackStage`` last **did not** place.
///
/// **For the screen reader** (finding B6, 2026-09-25): An unplaced message sits ten
/// thousand points below the area, and VoiceOver reads it out anyway. A `Layout` cannot
/// give its children a modifier; it therefore reports here, and
/// ``SwiftUI/View/feedback(_:state:)`` hides what is listed here.
///
/// **Reported after the pass and only on change** — writing in the middle of placing would
/// be a change during evaluation, and an equal value would trigger a pass that changes
/// nothing.
@MainActor
@Observable
final class FeedbackLayout {
    private(set) var unplaced: Set<Feedback> = []

    nonisolated init() {}

    nonisolated func notify(_ fresh: Set<Feedback>) {
        Task { @MainActor in
            if self.unplaced != fresh { self.unplaced = fresh }
        }
    }
}

/// Which feedback a view is on the ``FeedbackStage``.
struct FeedbackKind: LayoutValueKey {
    static let defaultValue: Feedback? = nil
}

extension View {
    /// Registers this view as feedback — see ``FeedbackStage``.
    ///
    /// **And hides it from the screen reader as long as the stage has not placed it**
    /// (``FeedbackLayout``).
    func feedback(_ kind: Feedback, state: FeedbackLayout) -> some View {
        accessibilityHidden(state.unplaced.contains(kind))
            .layoutValue(key: FeedbackKind.self, value: kind)
    }
}
