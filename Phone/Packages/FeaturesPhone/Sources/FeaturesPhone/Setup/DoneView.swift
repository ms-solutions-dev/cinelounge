import DesignSystemPhone
import SwiftUI

/// What is set up now.
///
/// **The rows are the answer to "did I do that right".** A "Done" without
/// a list leaves open whether the credential arrived — and whoever does not know that goes
/// back and sets up a second time.
///
/// **Next to it the way to parental controls** — the only moment at which anyone
/// thinks of it. Whoever looks for it later looks for it because something has already happened.
struct DoneView: View {

    let model: SourceFormModel
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MetricsBoard.phone.gutter) {
            Text(appKey: "setup.done.title")
                .font(TypeLevel.title.font)
                .foregroundStyle(ColorRole.text.color)

            ForEach(model.summary, id: \.self) { row in
                HStack(spacing: 8) {
                    // **The checkmark is there for the eye.** For the screen reader it would say
                    // "checkmark in circle, media server" — a symbol that is
                    // read out without saying anything. That the row is there IS
                    // the information; a checkmark in front of it only repeats it.
                    Image(systemName: Glyph.done.pair.filled)
                        .foregroundStyle(ColorRole.success.color)
                        .accessibilityHidden(true)
                    Text(verbatim: row)
                        .font(TypeLevel.footer.font)
                        .foregroundStyle(ColorRole.text.color)
                }
                .accessibilityElement(children: .combine)
            }

            // **What the credential said about itself** (AP2): a provider that only offers raw
            // streams runs through its own repackager — that stands here, at
            // entry, and not only at the first black picture.
            if let hint = model.accessHint {
                Footnote(wording: hint)
            }

            Button {
                model.complete()
                done()
            } label: {
                Text(appKey: "setup.done.go").frame(maxWidth: .infinity)
            }
            .buttonStyle(.loud)
            .padding(.top, MetricsBoard.phone.gutter)

            // **Not wired up yet, and it says so.** Parental controls are
            // AP24; a button that leads nowhere would be worse than none. The sentence
            // says where it will be later — that is the information this is about.
            Footnote(message: "setup.done.parental")
        }
        .padding(.horizontal, MetricsBoard.phone.margin)
        .padding(.top, MetricsBoard.phone.section)
    }
}
