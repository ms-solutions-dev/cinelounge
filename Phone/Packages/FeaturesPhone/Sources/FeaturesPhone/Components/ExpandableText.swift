import DesignSystemPhone
import SwiftUI

/// A text that is short at first and full on press.
///
/// **Four lines and then "more".** A synopsis is two lines long for some titles and twenty
/// for others; uncut, it pushes everything below out of the screen — on the detail page the
/// episode list, exactly what one came for.
///
/// **The button is only there if there is something to expand.** That is measured by the
/// drawn height and not by character count: how many lines a text needs depends on the type
/// size, and the viewer sets that.
struct ExpandableText: View {

    let text: String
    var rows = 4

    @State private var pending = false
    @State private var trimmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: text)
                .font(TypeLevel.text.font)
                .foregroundStyle(ColorRole.textMatt.color)
                .lineLimit(pending ? nil : rows)
                .background {
                    // The uncut text, invisible behind: if it is taller than the shown one, there is something
                    // to expand.
                    Text(verbatim: text)
                        .font(TypeLevel.text.font)
                        .hidden()
                        .background {
                            GeometryReader { full in
                                Color.clear.onAppear {
                                    trimmed = full.size.height > heightOf(rows)
                                }
                            }
                        }
                }

            if trimmed {
                Button {
                    withAnimation(Motion.expand) { pending.toggle() }
                } label: {
                    Text(app: pending ? "action.less" : "action.more")
                        .font(TypeLevel.footer.font)
                        .foregroundStyle(ColorRole.brandLight.color)
                }
                .buttonStyle(.plain)
                .textHitTarget()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func heightOf(_ rows: Int) -> CGFloat {
        TypeLevel.lineHeight(zu: 17) * CGFloat(rows) + 1
    }
}
