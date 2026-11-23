import DesignSystemPhone
import SwiftUI

/// Four dots and ten keys, in the lowest third.
///
/// **The position is the justification.** The design places the block at y 480 to 800
/// of 852, and that is no ornament: A PIN is entered standing, with one hand, and more
/// often than anything else in this part of the app. What lies at the top, the thumb
/// does not reach.
///
/// **The keys are large because they are hit blindly.** Whoever types a PIN looks at
/// the dots and not at the numbers — a key you have to search for costs the glance
/// that checks whether three dots are already filled.
///
/// **No check of its own, no store of its own.** This building block collects digits
/// and reports when there are enough; **what** a correct PIN is, only ``Pin`` knows
/// and nobody else. A numeric keypad that compared by itself would be a second place
/// with the same rule — and the second is always the one you forget when changing.
struct NumberPad: View {

    /// What has been entered so far.
    @Binding var digits: String

    /// How many digits are expected.
    var locations: Int

    /// Whether the last entry was wrong — the dots shake and turn red.
    var wrong = false

    /// The way out. **If it is missing, the key is missing too** — when setting a new PIN
    /// there is nothing to forget.
    var forgotten: (() -> Void)?

    /// Called as soon as the last digit is typed.
    var full: (String) -> Void

    var body: some View {
        VStack(spacing: MetricsBoard.phone.section) {
            points
            keys
        }
    }

    // MARK: - Die Punkte

    /// **Dots and no digits.** A PIN that stands in plain text while being typed
    /// gets read over the shoulder — and in this app it is read by the child it is
    /// meant for.
    private var points: some View {
        HStack(spacing: 18) {
            ForEach(0..<locations, id: \.self) { slot in
                Circle()
                    .fill(slot < digits.count ? color : Color.clear)
                    .overlay { Circle().strokeBorder(color, lineWidth: 1.5) }
                    .frame(width: 13, height: 13)
            }
        }
        .animation(Motion.expand, value: digits.count)
        // **One piece of information and not ten.** For the screen reader the number of
        // digits entered is the whole message; four circles read out individually
        // would be four announcements without meaning.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(appKey: wrong ? "pin.wrong" : "childLock.pin.dots"))
        .accessibilityValue(Text(verbatim: String(digits.count)))
    }

    private var color: Color { wrong ? ColorRole.brandLight.color : ColorRole.text.color }

    // MARK: - Die Tasten

    private var keys: some View {
        Grid(horizontalSpacing: MetricsBoard.phone.gutter, verticalSpacing: MetricsBoard.phone.gutter) {
            ForEach(Self.rows, id: \.first) { row in
                GridRow {
                    ForEach(row, id: \.self) { taste in
                        field(taste)
                    }
                }
            }
        }
        .padding(.horizontal, MetricsBoard.phone.margin)
    }

    /// Three rows of digits, then way out · zero · delete.
    private static let rows: [[String]] = [
        ["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["", "0", "⌫"],
    ]

    @ViewBuilder
    private func field(_ taste: String) -> some View {
        switch taste {
        case "":
            if let forgotten {
                Button(action: forgotten) {
                    Text(app: "pin.forgot")
                        .font(TypeLevel.label.font)
                        .foregroundStyle(ColorRole.textMatt.color)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: 62)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                // The spot stays empty and does not close up: Otherwise the zero would sit under
                // the seven instead of under the eight, and the thumb no longer finds it.
                Color.clear.frame(maxWidth: .infinity, minHeight: 62)
            }
        case "⌫":
            Button {
                if !digits.isEmpty { digits.removeLast() }
            } label: {
                Image(systemName: "delete.left")
                    .font(TypeLevel.section.font)
                    .foregroundStyle(ColorRole.textMatt.color)
                    .frame(maxWidth: .infinity, minHeight: 62)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(digits.isEmpty)
            .accessibilityLabel(Text(app: "common.delete"))
        default:
            Button {
                tap(taste)
            } label: {
                Text(verbatim: taste)
                    .iconSize(28, design: .rounded)
                    .monospacedDigit()
                    .foregroundStyle(ColorRole.text.color)
                    .frame(maxWidth: .infinity, minHeight: 62)
                    .background(ColorRole.surface.color, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    /// **The last digit reports by itself.** A "Continue" button under four digits would be
    /// a press that decides nothing — the entry is finished with the fourth digit,
    /// and every app that asks for a PIN does it this way.
    private func tap(_ digit: String) {
        guard digits.count < locations else { return }
        digits.append(digit)
        if digits.count == locations { full(digits) }
    }
}
