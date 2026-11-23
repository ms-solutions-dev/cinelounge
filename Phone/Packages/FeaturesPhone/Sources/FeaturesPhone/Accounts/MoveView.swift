import Core
import DesignSystemPhone
import Flows
import SwiftUI

/// "Server moved" is something different from "second server".
///
/// **The difference is the whole screen.** Whoever adds a second server has
/// two afterwards; whoever moves one still has one — at a new address, with
/// the same account, the same progress and the same favorites. Treated as a "second server",
/// the same catalog would be in the register twice, and the old entry would point
/// into the void.
///
/// **Two steps and not one: first check, then adopt.** The button writes
/// nothing until ``Flows/ServerMigrationFlow`` has confirmed that at the new address
/// **the same** server stands — the server identifier is compared and not the name.
/// "Jellyfin" is the shipping name; two servers called that are not uncommon.
struct MoveView: View {

    @State private var model = ServerMigrationFlow(sessionFrom: SecureStore())

    var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()

            ScrollSurface {
                VStack(alignment: .leading, spacing: MetricsBoard.phone.gutter) {
                    Text(appKey: "accounts.moveTitle")
                        .font(TypeLevel.title.font)
                        .foregroundStyle(ColorRole.text.color)

                    Text(appKey: "accounts.move.text")
                        .font(TypeLevel.footer.font)
                        .foregroundStyle(ColorRole.textMatt.color)
                        .fixedSize(horizontal: false, vertical: true)

                    field
                    finding
                    button

                    // **The warning stands above the footnote and not below it.** It is
                    // the one sentence that prevents a wrong move; a footnote below it is
                    // read by someone who has already pressed.
                    HintCapsule(message: "accounts.move.warning")

                    Footnote(message: "accounts.move.certNote")
                }
                .padding(.horizontal, MetricsBoard.phone.margin)
                .padding(.top, MetricsBoard.phone.gutter)
            }
        }
    }

    private var field: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title: "accounts.moveAddress")
                .padding(.horizontal, -MetricsBoard.phone.margin)
            InputField(
                text: $model.address, placeholder: "setup.server.placeholder", kind: .address)
            if let previous = model.previousAddress {
                Text(
                    verbatim: SettingsModel.text("accounts.move.before") + " " + previous
                )
                .font(TypeLevel.label.font)
                .foregroundStyle(ColorRole.textQuiet.color)
            }
        }
        .padding(.top, MetricsBoard.phone.gutter)
    }

    /// What the comparison has yielded — **always with the name the server states.**
    ///
    /// Without it, it would say "the same server", and nobody could check whether that is true.
    @ViewBuilder
    private var finding: some View {
        switch model.finding {
        case .pending:
            EmptyView()
        case .isRunning:
            LoadingState(message: "setup.server.checking")
        case .sameOne(let name):
            UserNotice(
                icon: Glyph.done.pair.outlined, color: ColorRole.success.color,
                message: "accounts.move.same", name: name)
        case .other(let name):
            UserNotice(
                icon: Glyph.warning.name, color: ColorRole.progress.color,
                message: "accounts.move.other", name: name)
        case .withoutIdentifier(let name):
            UserNotice(
                icon: Glyph.warning.name, color: ColorRole.progress.color,
                message: "accounts.move.unknownID", name: name)
        case .error(let key):
            HintCapsule(message: key)
        case .relocated(let count):
            UserNotice(
                icon: Glyph.done.pair.outlined, color: ColorRole.success.color,
                message: "accounts.move.done",
                name: SettingsModel.text("accounts.move.moved", count))
        }
    }

    @ViewBuilder
    private var button: some View {
        if model.asksForConsent {
            // **The path that did not exist here until 2026-09-21** (AP41). Without a verifiable
            // identifier, the message stood there and nothing else — a dead end for everyone
            // whose credential dates from the time before ``ServerCredentials/serverID``. The
            // TV showed in the same case a sentence and below it a button; the
            // shared rule (``Core/ServerMove``) is: do not guess, ask.
            //
            // **Quiet and not loud.** A move that nobody could verify is not
            // the recommended action — drawing it loudly would mean recommending it.
            Button {
                model.confirmWithoutID()
            } label: {
                Text(appKey: "accounts.move.anyway").frame(maxWidth: .infinity)
            }
            .buttonStyle(.quiet)
        } else if model.isAdoptable {
            Button {
                model.adopt()
            } label: {
                Text(appKey: "accounts.moveConfirm").frame(maxWidth: .infinity)
            }
            .buttonStyle(.loud)
        } else {
            Button {
                Task { await model.verify() }
            } label: {
                Text(appKey: "accounts.move.check").frame(maxWidth: .infinity)
            }
            .buttonStyle(.loud)
            .disabled(model.address.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}

/// A finding with symbol, sentence and the name it is about.
///
/// **The symbol carries the information, the color only reinforces it.** A checkmark versus a
/// warning triangle can be told apart even under deuteranopia; green versus gold cannot.
private struct UserNotice: View {

    let icon: String
    let color: Color
    /// Key in the catalog.
    let message: String
    /// Finished wording — the name the server states.
    let name: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(appKey: message)
                    .foregroundStyle(ColorRole.text.color)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: name)
                    .foregroundStyle(ColorRole.textQuiet.color)
            }
        }
        .font(TypeLevel.footer.font)
        .accessibilityElement(children: .combine)
    }
}
