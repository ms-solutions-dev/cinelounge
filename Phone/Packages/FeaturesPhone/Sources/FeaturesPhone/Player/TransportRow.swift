import DesignSystemPhone
import SwiftUI

/// Back, pause, forward — the three buttons in the middle.
///
/// **–10 and +30, not symmetric.** You jump back because you missed something (a
/// sentence, ten seconds); forward because something is not interesting (an intro,
/// thirty). Two equal numbers would be the more convenient choice and the worse one.
///
/// **In the middle and large.** The pause button is the most pressed of the whole screen;
/// it sits where the thumb lies in landscape, and measures 64 instead of 44 points.
///
/// **Since AP58 G1 like on the TV** (decision 27): chapters on the outside if the title
/// has any (A5), and for a channel in the buffer "Back to live" (A1). A channel without a
/// buffer has no jump buttons — a button that is supposed to jump back ten seconds while
/// the programme is running is one without effect.
struct TransportRow: View {

    let isRunning: Bool
    let jump: (TimeInterval) -> Void
    let setEnabled: () -> Void
    /// Whether jumping is possible — a recording or a channel in the buffer.
    var isSeekable = true
    /// The chapter jump, **only where the title has chapters.**
    var chapters: ((_ forward: Bool) -> Void)?
    /// Back to the running programme, **only behind the live edge.**
    var toLive: (() -> Void)?

    var body: some View {
        HStack(spacing: chapters == nil ? 32 : 20) {
            if let chapters {
                button(Glyph.chapterBack.name, "player.chapterBack", size: 22) {
                    chapters(false)
                }
            }
            if isSeekable {
                button(Glyph.tenBack.name, "player.back10", size: 28) { jump(-10) }
            }

            Button(action: setEnabled) {
                Image(systemName: isRunning ? Glyph.pause.name : Glyph.play.name)
                    .iconSize(30, weight: .semibold)
                    .foregroundStyle(ColorRole.text.color)
                    .frame(width: 64, height: 64)
                    .background(Material.chromeBar, in: Circle())
                    .edge()
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(app: isRunning ? "common.pause" : "common.play"))

            if isSeekable {
                button(Glyph.thirtyForward.name, "player.forward30", size: 28) { jump(30) }
            }
            if let chapters {
                button(Glyph.chapterForward.name, "player.chapterNext", size: 22) {
                    chapters(true)
                }
            }
            if let toLive {
                button(Glyph.backToLive.name, "player.toLive", size: 24, action: toLive)
            }
        }
    }

    private func button(
        _ icon: String, _ label: String, size: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .iconSize(size, weight: .medium)
                .foregroundStyle(ColorRole.text.color)
                .frame(width: Metrics.target, height: Metrics.target)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(appKey: label))
    }
}
