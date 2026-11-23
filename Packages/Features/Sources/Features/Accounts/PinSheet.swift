import Core
import DesignSystem
import ParentalControls
import ProfileKit
import SwiftUI

/// The PIN entry on the TV.
///
/// **On the phone this is a number field; here it is a different task.** Four digits
/// via an on-screen keyboard at three meters, with a remote, in
/// a room where someone is watching — each of these four conditions changes something.
///
/// **The digits are not shown in plain text, but their count is.** Dots instead of digits,
/// four places visible: Whoever cannot see how far they are starts over after a typo
/// — and on the remote the typo is the rule.
///
/// **The keys are shuffled, and that is the real reason for this sheet.**
/// A number pad in row form can be read along on 55 inches from two meters away
/// — not on the screen, but **from the hand movement**. Whoever knows the layout
/// reads the PIN from the direction of the thumb. For a lock that is meant to protect
/// precisely from children sitting next to you, that is no edge case.
/// The shuffle is rolled **once per sheet** and not on every redraw: A
/// keyboard that jumps under the finger is unusable. **The rules — places,
/// shuffling, reshuffling after a failed attempt — have lived in
/// ``ParentalControls/PinEntry`` since AP58 R2**; only the focus grid is here.
///
/// **No counter and no lockout after three attempts.** Four digits are 10,000
/// possibilities, and entry on the remote costs seconds; whoever wants to guess
/// needs days. A lockout after three failed attempts would on the other hand reliably hit
/// the parent who mistyped — and they would then have a device that no longer
/// obeys them. The way out remains ``LockedDoors`` "pinVergessen".
struct PinSheet: View {

    /// What lies behind the door — the sentence from ``LockedDoors``. When setting, the
    /// sentence of the stage (``hint``) stands in its place.
    let reason: String?
    /// Accepts the entered digits. `false` means: wrong. **When
    /// setting**, the PIN typed the same twice arrives here exactly once.
    let onSubmit: (String) -> Bool
    let onCancel: () -> Void
    /// Setting a new PIN instead of checking an existing one — **twice, without a display
    /// in between**; if they differ, it starts over (``ParentalControls/PinEntry``).
    ///
    /// **Until AP58 R2 ``PinSetSheet`` built the repetition itself**, by returning the first
    /// entry as "wrong" — and the sheet reported "PIN wrong" after every first entry.
    /// Now the sheet knows the stage and reports only what is one.
    let assigns: Bool
    /// The third button — **`nil` means: this sheet has no way out** (AP43).
    ///
    /// It is missing where there is nothing to unlock: when **setting** a new PIN and
    /// for a profile whose PIN is not the household's. A way out that stands in the
    /// wrong place is a door in the wall.
    let onForgot: (() -> Void)?

    @State private var input: PinEntry
    @State private var wrong = false
    /// The last repetition differed — the sentence says so until the next digit arrives.
    @State private var deviation = false

    init(
        reason: String?, onSubmit: @escaping (String) -> Bool, onCancel: @escaping () -> Void,
        onForgot: (() -> Void)? = nil, assigns: Bool = false
    ) {
        self.reason = reason
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        self.onForgot = onForgot
        self.assigns = assigns
        _input = State(initialValue: PinEntry(start: assigns ? .fresh : .verify))
    }

    @FocusState private var focus: String?

    var body: some View {
        VStack(spacing: 30) {
            Text(app: "pin.enter")
                .font(TypeLevel.section.font)
                .foregroundStyle(ColorRole.text.color)

            if let message = assigns ? hint : reason {
                Text(verbatim: message)
                    .font(TypeLevel.footer.font)
                    .foregroundStyle(ColorRole.textMatt.color)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 760)
            }

            points

            if wrong {
                Text(app: "pin.wrong")
                    .font(TypeLevel.footer.font)
                    .foregroundStyle(ColorRole.live.color)
            }

            block

            HStack(spacing: 18) {
                button("common.delete", identifier: "loeschen") {
                    input.deleteLast()
                    wrong = false
                }
                button("common.cancel", identifier: "abbrechen", action: onCancel)
                // **The way out stands next to Cancel and not above it.** Whoever
                // looks for it looks for it at the bottom; whoever does not should not
                // meet it first — on the remote the mispress is the rule.
                if let onForgot {
                    button("pin.forgot", identifier: "vergessen", action: onForgot)
                }
            }
        }
        .padding(40)
    }

    /// The sentence of the stage when setting.
    private var hint: String {
        let key: String.LocalizationValue =
            deviation
            ? "pin.mismatch"
            : input.tier == .repeatEntry ? "pin.repeat" : "pin.enterNew"
        return AppLanguageSetting.text(key)
    }

    /// Four places, filled or empty.
    private var points: some View {
        HStack(spacing: 22) {
            ForEach(0..<Pin.locations, id: \.self) { location in
                Circle()
                    .fill(
                        location < input.digits.count
                            ? ColorRole.text.color : ColorRole.surfaceHigh.color
                    )
                    .frame(width: 22, height: 22)
            }
        }
        .padding(.vertical, 8)
    }

    /// The shuffled block, five keys per row.
    private var block: some View {
        VStack(spacing: 16) {
            ForEach(0..<2, id: \.self) { row in
                HStack(spacing: 16) {
                    ForEach(input.keys[(row * 5)..<(row * 5 + 5)], id: \.self) { digit in
                        digitKey(digit)
                    }
                }
            }
        }
    }

    private func digitKey(_ digit: Int) -> some View {
        Button {
            tap(digit)
        } label: {
            Text(verbatim: String(digit))
                .font(TypeLevel.header.font)
                .foregroundStyle(
                    focus == "z\(digit)" ? ColorRole.reason.color : ColorRole.text.color
                )
                .frame(width: 96, height: 72)
                .background(
                    focus == "z\(digit)" ? ColorRole.text.color : ColorRole.surface.color,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
        }
        .bareFocusableButton()
        .focused($focus, equals: "z\(digit)")
    }

    /// **The fourth digit submits** — there is no confirm button
    /// (``ParentalControls/PinEntry/tap(_:)``). If it is wrong, the sheet stays,
    /// empties and reshuffles.
    private func tap(_ digit: Int) {
        wrong = false
        deviation = false
        guard let full = input.tap(digit) else { return }
        switch input.take(full, verify: onSubmit) {
        case .wrong:
            wrong = true
        case .deviation:
            deviation = true
        case .chosen(let pin):
            if !onSubmit(pin) {
                input = PinEntry(start: .fresh)
                wrong = true
            }
        case .verified, .repeatEntry:
            break
        }
    }

    private func button(
        _ key: String, identifier: String, action: @escaping () -> Void
    )
        -> some View
    {
        Button(action: action) {
            Text(appKey: key)
                .font(TypeLevel.footer.font)
                .settingsFont(isFocused: focus == identifier, muted: true)
                .settingsSurface(.pill, isFocused: focus == identifier)
        }
        .bareFocusableButton()
        .focused($focus, equals: identifier)
    }
}
