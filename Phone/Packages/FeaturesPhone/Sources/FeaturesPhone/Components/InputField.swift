import DesignSystemPhone
import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

/// A field.
///
/// **Addresses and keys in monospaced type.** There every character counts individually, and
/// an `l` versus a `1` decides an hour of troubleshooting. Names and ordinary text get the
/// normal type — there monospace would only be ornament.
///
/// **The border turns to the accent color, not the fill.** A filled area in the editing state
/// attracts more attention than the text one is just typing.
struct InputField: View {

    enum Kind: Sendable {
        case text
        /// An address: monospaced, no capitalization, no autocorrection.
        case address
        case name
        /// A password — with an eye button.
        ///
        /// **A password that is typed on an on-screen keyboard and must not be seen gets guessed on
        /// the third attempt.** The button is not a concession to convenience but the condition for a
        /// long password being enterable at all.
        case password
    }

    @Binding var text: String
    /// Key in the catalog.
    let placeholder: String
    var kind: Kind = .text

    @State private var isVisible = false
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            field
            if kind == .password {
                Button {
                    isVisible.toggle()
                } label: {
                    Image(systemName: isVisible ? "eye.slash" : "eye")
                        .foregroundStyle(ColorRole.textQuiet.color)
                }
                .frame(width: 32, height: 32)
                .accessibilityLabel(Text(appKey: isVisible ? "field.hide" : "field.show"))
            }
        }
        .padding(.horizontal, Metrics.cardInset)
        .frame(minHeight: 50)
        .background(
            ColorRole.surface.color, in: RoundedRectangle(cornerRadius: MetricsBoard.phone.fieldRadius)
        )
        .overlay {
            RoundedRectangle(cornerRadius: MetricsBoard.phone.fieldRadius)
                .strokeBorder(
                    isFocused ? ColorRole.brandLight.color : ColorRole.outline.color,
                    lineWidth: isFocused ? 1 : 0.5)
        }
    }

    @ViewBuilder
    private var field: some View {
        Group {
            if kind == .password && !isVisible {
                SecureField(
                    "", text: $text,
                    prompt: Text(appKey: placeholder).foregroundStyle(ColorRole.textQuiet.color))
            } else {
                TextField(
                    "", text: $text,
                    prompt: Text(appKey: placeholder).foregroundStyle(ColorRole.textQuiet.color))
            }
        }
        .focused($isFocused)
        .foregroundStyle(ColorRole.text.color)
        .font(kind == .address ? TypeLevel.text.font.monospaced() : TypeLevel.text.font)
        .autocorrectionDisabled(kind != .name)
        // **Only where there is an on-screen keyboard.** macOS is built here so that `swift test`
        // runs on the Mac — the same barrier as at ``Haptics``. What concerns the keyboard does not
        // exist there, and the build would break on it.
        .keyboardType(kind)
    }
}

extension View {

    /// What the on-screen keyboard needs to know about this field.
    ///
    /// **Extracted because it would put half the file under a switch.** An `#if` in the middle of
    /// a modifier chain splits it into two branches that drift apart — here the switch stands
    /// once.
    @ViewBuilder
    fileprivate func keyboardType(_ kind: InputField.Kind) -> some View {
        #if canImport(UIKit)
            let content: UITextContentType? =
                switch kind {
                case .address: .URL
                case .password: .password
                case .name: .username
                case .text: nil
                }
            self
                .textContentType(content)
                .textInputAutocapitalization(kind == .name ? .words : .never)
                .keyboardType(kind == .address ? .URL : .default)
        #else
            self
        #endif
    }
}
