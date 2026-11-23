import DesignSystemPhone
import SwiftUI

/// The sentence that explains a catalog or a decision.
///
/// **Fifty-two times in the design and the longest body of text in it.** A footnote is no
/// error and no warning: it sits quietly beneath what it explains, and it demands nothing.
/// Where it became a button it would be a task — and tasks have their own form
/// (``StateBlock``).
///
/// **It wraps and is not cut off.** Half a sentence explains nothing; if the footnote needs
/// three lines, it takes three lines.
struct Footnote: View {
    /// How far the row indents — ``Styling/MetricsBoard/margin`` on the background,
    /// ``Metrics/cardInset`` in an ``SettingsCard``.
    @Environment(\.rowInset) private var inset

    /// Key in the catalog.
    var message: String?
    /// Finished wording — for sentences with inserted numbers or names.
    var wording: String?

    var body: some View {
        Group {
            if let wording {
                Text(verbatim: wording)
            } else if let message {
                Text(appKey: message)
            }
        }
        .font(TypeLevel.label.font)
        // **Matte, not quiet** (2026-09-07). The prototype prescribes it literally: "The footnotes are
        // half the value of these areas; they are therefore set in 13 px on `--a-matt` (7.85 : 1)
        // **and not in a gray line in `--a-quiet`**." What was built was the forbidden gray line, at
        // sixty-four call sites. ``Styling/ColorRole/textQuiet`` is reserved for accessories and
        // times — an explanatory sentence is reading text.
        .foregroundStyle(ColorRole.textMatt.color)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        // **It pads itself, and nobody from outside may add more** (2026-09-09). Since it reads
        // ``Zeileneinzug``, the inset here is complete — at five call sites the old
        // `.padding(.horizontal, MetricsBoard.phone.margin)` from the time before still stood, and the
        // sentences began there at **40** instead of 20 points, thus twice as far in as the card
        // above. Found on the accounts sheet; all five have been fixed.
        .padding(.horizontal, inset)
        .padding(.vertical, MetricsBoard.phone.gutter)
    }
}
