import DesignSystemPhone
import SwiftUI

/// Language and diagnostics — **even before sign-in.**
///
/// **The sentence stood in the head of ``SourceFormView`` since AP21 and the row nowhere.**
/// Recounted on 2026-09-06: the body consisted of head, step and a `Spacer`. A
/// promise in the source that has no place where it is kept is worse than none — it
/// reassures while reading and is missing in use.
///
/// **Why both belong exactly here: whoever cannot get in needs them most
/// urgently.** Diagnostics otherwise stand behind sign-in — that is, behind exactly the
/// door at which someone fails who would need them. And the language decides whether they can read the
/// error message at all; searching for it afterwards presupposes that they understand the
/// interface they currently do not understand.
///
/// **On the TV it stands there for the same reason** — the same rule, the same place.
struct SetupFooter: View {

    /// The choice **of the active profile** (AP46) — see ``AppearanceView``.
    @State private var language = LanguageChoice.chosen()
    @State private var showsDiagnostics = false

    var body: some View {
        HStack(spacing: MetricsBoard.phone.gutter) {
            languageChoice
            Spacer(minLength: Metrics.targetSpacing)
            Button {
                showsDiagnostics = true
            } label: {
                // **`settings.diagnose` and not `settings.diagnostics`** (finding of
                // 2026-09-09, on screen): the second key does not exist — in the catalog
                // it is the stem of twenty-four subkeys
                // (`settings.diagnostics.log`, `…​.send`, …), but not an entry of its own.
                // SwiftUI shows an unknown key as itself, and so
                // under the setup the literal text `settings.diagnostics` appeared.
                Label(app: "settings.diagnose", systemImage: Glyph.check.name)
                    .font(TypeLevel.footer.font)
                    .foregroundStyle(ColorRole.textMatt.color)
                    .labelStyle(.titleAndIcon)
            }
            .textHitTarget()
        }
        .padding(.horizontal, MetricsBoard.phone.margin)
        .padding(.bottom, MetricsBoard.phone.gutter)
        .frame(maxWidth: .infinity)
        // **A sheet and not a path.** The setup runs before there is a tab bar;
        // there is no signpost leading back here at this point.
        .sheet(isPresented: $showsDiagnostics) {
            DiagnoseView()
                .presentationDetents([.large])
                .presentationCornerRadius(MetricsBoard.phone.sheetRadius)
                .presentationBackground(ColorRole.reason.color)
        }
    }

    /// **A menu and not a list.** Four languages as rows would be half the
    /// screen — and at a spot where nobody looks as long as everything is
    /// understandable.
    private var languageChoice: some View {
        Menu {
            // **The languages stand in their own language.** "Turkish" helps
            // nobody who searches for "Türkçe" — and whoever cannot read the interface right now
            // searches exactly that way. The same list as in ``AppearanceView``, from the
            // same source — since 2026-09-07 that is ``DesignSystemPhone/LanguageChoice``
            // and no longer a board in one of the two views.
            ForEach(LanguageChoice.isOffered, id: \.identifier) { entry in
                Button {
                    // **The second write site was the second half of the finding.**
                    // Here too only `language = …` stood, that is only `app.language` —
                    // and nobody read it. Both paths now go through ``LanguageChoice``.
                    LanguageChoice.set(entry.identifier)
                    language = entry.identifier
                } label: {
                    if language == entry.identifier {
                        Label(entry.name, systemImage: Glyph.done.pair.filled)
                    } else {
                        Text(verbatim: entry.name)
                    }
                }
            }
        } label: {
            Label {
                Text(verbatim: selectedLanguage)
            } icon: {
                Image(systemName: "globe")
            }
            .font(TypeLevel.footer.font)
            .foregroundStyle(ColorRole.textMatt.color)
        }
        .textHitTarget()
        .accessibilityLabel(Text(app: "settings.language"))
        .accessibilityValue(Text(verbatim: selectedLanguage))
    }

    private var selectedLanguage: String {
        LanguageChoice.isOffered.first { $0.identifier == language }?.name
            ?? LanguageChoice.isOffered[0].name
    }
}
