import DesignSystemPhone
import SwiftUI

/// A search field, the same everywhere.
///
/// **It searches in memory, not on the server** — at least where it stands today. In
/// the category chooser a hundred and eight names are long since loaded; filtering
/// them costs no request, and with a provider account with **one** permitted
/// connection that is exactly the point. Where it later searches a catalog (AP20),
/// the same rule applies: filter first what is there, and load only what is missing.
///
/// **The cross to clear is a target of its own.** A field that can be reset only by
/// deleting costs twenty keystrokes with a long term — and the thumb lies on the
/// delete key instead of on the result.
struct SearchField: View {

    @Binding var text: String
    /// Key in the catalog.
    var placeholder: String

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: Glyph.Tab.search.outlined)
                .iconSize(14)
                .foregroundStyle(ColorRole.textQuiet.color)

            TextField(
                "", text: $text,
                prompt: Text(appKey: placeholder).foregroundStyle(ColorRole.textQuiet.color)
            )
            .font(TypeLevel.text.font)
            .foregroundStyle(ColorRole.text.color)
            .asSearchTerm()
            .submitLabel(.search)
            .focused($isFocused)
            // **The placeholder is not a label.** VoiceOver reads it only while nothing is typed;
            // as soon as a term is typed, the field announces itself as "text field" and no
            // longer says what it searches for.
            .accessibilityLabel(Text(appKey: placeholder))

            if !text.isEmpty {
                Button {
                    text = ""
                    isFocused = true
                } label: {
                    Image(systemName: Glyph.close.name)
                        .iconSize(12, weight: .semibold)
                        .foregroundStyle(ColorRole.textMatt.color)
                }
                .buttonStyle(.plain)
                .textHitTarget()
                .accessibilityLabel(Text(app: "settings.clearCache"))
            }
        }
        .padding(.horizontal, Metrics.pillInset)
        .frame(minHeight: Metrics.target)
        .background(ColorRole.surface.color, in: Capsule())
        .overlay { Capsule().strokeBorder(ColorRole.outline.color, lineWidth: 0.5) }
    }
}
