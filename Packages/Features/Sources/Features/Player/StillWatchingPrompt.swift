import Core
import DesignSystem
import Flows
import SwiftUI

/// "Still watching?" — after a few episodes without a press (AP85 binge package, 2026-11-09).
///
/// The picture stands paused behind it. **Keep watching is the default focus**: whoever is
/// awake presses once and goes on; whoever slept wakes to a held picture instead of four
/// episodes later.
struct StillWatchingPrompt: View {

    let episodeTitle: String?
    @FocusState.Binding var focus: String?
    let onContinue: () -> Void
    let onStop: () -> Void

    @Environment(\.accentPalette) private var palette

    var body: some View {
        ZStack {
            ColorRole.reason.color.opacity(0.6).ignoresSafeArea()
            VStack(spacing: 28) {
                Text(appKey: "player.stillWatching")
                    .font(TypeLevel.header.font)
                    .foregroundStyle(ColorRole.text.color)
                if let episodeTitle {
                    Text(verbatim: episodeTitle)
                        .font(TypeLevel.footer.font)
                        .foregroundStyle(ColorRole.textMatt.color)
                        .lineLimit(1)
                }
                HStack(spacing: 24) {
                    button("player.keepWatching", identifier: "still-continue", action: onContinue)
                    button("player.stopWatching", identifier: "still-stop", action: onStop)
                }
                .padding(.top, 12)
            }
            .focusSection()
        }
    }

    private func button(
        _ key: String, identifier: String, action: @escaping () -> Void
    )
        -> some View
    {
        let isFocused = focus == identifier
        return Button(action: action) {
            Text(appKey: key)
                .font(TypeLevel.footer.font)
                .fontWeight(.semibold)
                .foregroundStyle(isFocused ? ColorRole.text.color : ColorRole.reason.color)
                .padding(.horizontal, 32)
                .frame(height: 56)
                .background(isFocused ? Color(palette) : ColorRole.text.color, in: Capsule())
        }
        .bareFocusableButton()
        .focused($focus, equals: identifier)
        .focusHighlight(isFocused, scale: Tokens.Focus.buttonScale, accent: Color(palette, .bright))
        .info(appKey: key)
    }
}
