import DesignSystemPhone
import SwiftUI

/// The jump bar at the right edge of a long list.
///
/// **Why it has to exist:** In one category the provider carries up to 4,211 titles —
/// that is six hundred screens. Whoever knows the title they are looking for swipes past
/// it three hundred times.
///
/// **It is drawn narrow and grabbed wide.** The finding of 2026-09-05: the hit area was as
/// wide as the drawing — **sixteen points**, and the rule demands forty-four in **both**
/// axes. The reasoning "the target is the bar, not the glyph" covers the height, not the
/// width. Apple's own model draws narrow and grabs wide; that is exactly what stands
/// here now.
///
/// **Only marks that have content.** A jump to nothing is worse than no jump — it looks
/// as if the app had lost the title. And the marks come from the same computation as the
/// sorting: letters for A–Z, years for "Newest first", rating bands for "Rating". See
/// ``Sorting/tag(forItem:)``.
struct JumpBar: View {

    let marks: [String]
    let jump: (String) -> Void

    @State private var last: String?

    /// The drawn width.
    static let width: CGFloat = 16

    /// How much space it claims at the right edge — drawing plus air.
    static let slot: CGFloat = width

    /// How wide it is **grabbed**.
    static let grabWidth: CGFloat = Metrics.target

    var body: some View {
        GeometryReader { space in
            VStack(spacing: 0) {
                ForEach(marks, id: \.self) { tag in
                    Text(verbatim: tag)
                        // **Scaling type.** Before, a fixed ten stood here — below the smallest step of the
                        // design, and it never grew with Dynamic Type. At the accessibility sizes it was the
                        // only element in dwarf type.
                        .font(TypeLevel.lowercased.font)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(ColorRole.brandLight.color)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: Self.width)
            // **Drawn on the right, grabbed wide.** The frame is forty-four points wide and
            // right-aligned; the letters sit in it at the right edge. The list does not get
            // narrower because of it — the space it keeps free is ``slot``, and the rest of the
            // area lies over the content.
            .frame(width: Self.grabWidth, alignment: .trailing)
            .contentShape(Rectangle())
            .gesture(
                // **A drag and not a tap.** `DragGesture(minimumDistance: 0)` catches both: the first
                // contact already jumps, and whoever leaves the finger down keeps moving. One
                // `onTapGesture` per mark would be twenty-six targets of twenty points in height each.
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let portion = drag.location.y / max(1, space.size.height)
                        let location = Int(portion * CGFloat(marks.count))
                        guard marks.indices.contains(location) else { return }
                        let tag = marks[location]
                        // **Only on change.** Without this guard every intermediate frame fires the same jump
                        // — and a jump back to the same spot takes all inertia away from the list.
                        guard tag != last else { return }
                        last = tag
                        jump(tag)
                    }
                    .onEnded { _ in last = nil }
            )
            .overlay(alignment: .trailing) {
                // **The callout to the left of the finger.** Without it, the mark that was hit is
                // exactly the one the thumb covers — you drag blind.
                if let last {
                    Text(verbatim: last)
                        .font(TypeLevel.title.font)
                        .monospacedDigit()
                        .foregroundStyle(ColorRole.text.color)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Material.chromeBar, in: Capsule())
                        .edge()
                        .offset(x: -Self.grabWidth - MetricsBoard.phone.gutter)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
        }
        .frame(width: Self.grabWidth)
        // **The detent of the bar.** The thumb rests on the marks and covers them; the callout
        // stands next to it, but whoever drags looks at the list and not at the callout. The
        // tap says "one mark further" without having to look.
        //
        // **Only on contact, not on release.** ``last`` falls back to `nil` in `onEnded`;
        // without the condition each jump would get a second tap once the finger is already
        // gone.
        .haptics(.snapped, at: last, when: { _, fresh in fresh != nil })
        .accessibilityHidden(true)
    }
}
