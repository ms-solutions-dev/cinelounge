import DesignSystemPhone
import SwiftUI

/// The dots below the header area: how many there are and which one is current.
///
/// **They are the answer to the question of whether there is more.** A box that pages on its
/// own looks without them like an ad that rotates; with them it is a selection one can also
/// swipe through oneself. Exactly for that reason they sit **below** the box and not in it —
/// in the image they would be decoration, below it they are a control.
///
/// **No separate touch area.** A dot is four points wide; making it hittable would mean
/// giving it an invisible area 44 points tall, and eight of them side by side would cover
/// half the box edge. Swiping happens on the box itself — there the area is as big as the
/// image.
struct PageDots: View {

    let count: Int
    let settled: Int

    var body: some View {
        if count > 1 {
            HStack(spacing: 6) {
                ForEach(0..<count, id: \.self) { number in
                    Circle()
                        .fill(
                            number == settled ? ColorRole.text.color : ColorRole.textQuiet.color.opacity(0.4)
                        )
                        .frame(width: 6, height: 6)
                }
            }
            .animation(Motion.expand, value: settled)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(app: "home.hero.pager"))
            .accessibilityValue(Text(verbatim: "\(settled + 1)/\(count)"))
        }
    }
}
