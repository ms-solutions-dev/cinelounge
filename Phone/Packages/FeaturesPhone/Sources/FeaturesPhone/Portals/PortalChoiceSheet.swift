import DesignSystemPhone
import SwiftUI

/// Sheet: the portals, each with its state.
///
/// **The state is in the list, not only behind the press.** It is a
/// property of the portal and not an error message — whoever learns only after opening
/// that a sign-in is missing takes the app to be broken.
///
/// **A silent portal stays visible and only becomes unselectable.** Taking it out of the list
/// would be more convenient and would destroy information: "does not answer" answers
/// the question of why there is nothing there today; a missing entry answers nothing at all.
///
/// **A row of its own instead of ``ChoiceRow``.** Its subline is text, and the state
/// needs a symbol — "never color alone" could not otherwise be kept.
struct PortalChoiceSheet: View {

    let portals: [PortalInfo]
    let chosen: String?
    let select: (PortalInfo) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(portals) { portal in
                row(portal)
            }
            // **Here it rests after reading** — one opens the portal choice to
            // choose, not to read. In Settings it stays permanently.
            PortalsHint(restsAfterReading: true)
                .padding(.top, MetricsBoard.phone.section)
        }
    }

    private func row(_ portal: PortalInfo) -> some View {
        Button {
            select(portal)
        } label: {
            HStack(spacing: MetricsBoard.phone.gutter) {
                // The checkmark holds its place even when it is not there — otherwise
                // all names shift as soon as one chooses something else.
                Image(systemName: Glyph.done.pair.outlined)
                    .foregroundStyle(portal.id == chosen ? ColorRole.brandLight.color : .clear)

                badge(portal)

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: portal.name)
                        .font(TypeLevel.text.font)
                        .foregroundStyle(ColorRole.text.color)
                    subRow(portal)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, MetricsBoard.phone.margin)
            .frame(minHeight: Metrics.choiceRow)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!portal.state.isSelectable)
        .opacity(portal.state.isSelectable ? 1 : 0.55)
    }

    private func badge(_ portal: PortalInfo) -> some View {
        Text(verbatim: portal.abbreviation)
            .font(TypeLevel.lowercased.font)
            .foregroundStyle(ColorRole.text.color)
            .frame(width: 38, height: 30)
            .background(ColorRole.surfaceHigh.color, in: RoundedRectangle(cornerRadius: 7))
    }

    private func subRow(_ portal: PortalInfo) -> some View {
        HStack(spacing: 6) {
            StateBadge(state: portal.state)
            // **"Plays immediately" only where it is true and changes something.** On a
            // portal that is not ready anyway, it would be a promise without backing.
            if portal.state.isReady && portal.playsImmediately {
                Text(verbatim: "·").foregroundStyle(ColorRole.textQuiet.color)
                Text(appKey: "portal.playsAtOnce")
                    .font(TypeLevel.label.font)
                    .foregroundStyle(ColorRole.textQuiet.color)
            }
        }
    }
}

/// Why there is nothing to set up here.
///
/// **The sentence is there so that nobody rebuilds it.** The app knows the bridge's portal
/// addresses and cannot add any — that is the answer to App Store rule 2.5.2 and
/// must not be loosened on the phone. Without the sentence the missing
/// add option looks like a gap, and the next hand closes it.
struct PortalsHint: View {

    /// Whether it may rest once it has been read.
    ///
    /// **Show once, then rest.** It costs space on every call of the portal choice, and
    /// its information never changes — whoever has read it once does not read it
    /// again the twentieth time. **It must still not disappear entirely:**
    /// in `Settings → Portals` and in setup it stays permanently, because there
    /// one goes **in order to** read it. That is why the call site decides.
    var restsAfterReading = false

    @AppStorage("portal.hinweisGelesen") private var read = false

    var body: some View {
        if restsAfterReading && read {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Footnote(message: "portal.whyNoAdding")
                if restsAfterReading {
                    Button {
                        read = true
                    } label: {
                        Text(appKey: "portal.note.hide")
                            .font(TypeLevel.label.font)
                            .foregroundStyle(ColorRole.textMatt.color)
                            .frame(minHeight: Metrics.target, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, MetricsBoard.phone.margin)
                }
            }
        }
    }
}
