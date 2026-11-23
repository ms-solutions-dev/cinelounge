import Core
import DesignSystem
import Flows
import SwiftUI

/// Asks for the new address of a server that has moved and rewrites it.
///
/// **The difference between a move and a second server is the whole view.** Without the
/// confirmation step this would be a text field with a button; with it, it is a flow that
/// catches a wrong entry **before** it layers two catalogs on top of each other. The
/// decision is made on the server ID and not on the name — a hostname changes
/// during a move, after all.
///
/// **The flow has been shared since AP58 R7** (``Flows/ServerMigrationFlow``, finding E2);
/// on the TV the account of the selected profile moves, on the phone the session.
struct MoveView: View {

    /// The account whose server is moving — for the "from" row.
    let account: Account
    @State var model: ServerMigrationFlow
    /// Called when the move is done — the list above has to reread.
    let onDone: () -> Void
    let onCancel: () -> Void

    @FocusState private var focus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            Text(app: "accounts.moveTitle")
                .font(TypeLevel.section.font)
                .foregroundStyle(ColorRole.text.color)

            Text(app: "accounts.moveExplain")
                .font(TypeLevel.lowercased.font)
                .foregroundStyle(ColorRole.textQuiet.color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 900, alignment: .leading)

            // The old address is shown and cannot be changed: it is the
            // starting point and not an input.
            HStack(spacing: 14) {
                Text(app: "accounts.moveFrom")
                Text(verbatim: account.serverName)
                    .foregroundStyle(ColorRole.text.color)
            }
            .font(TypeLevel.footer.font)
            .foregroundStyle(ColorRole.textMatt.color)

            content
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        switch model.finding {
        case .pending, .error:
            input
        case .isRunning:
            LoadingBand()
                .padding(.vertical, 20)
        case .sameOne(let name):
            // The same server — this is the case the ID exists for.
            decision(
                title: "accounts.moveSameServer", name: name, continueKey: "accounts.moveConfirm")
        case .withoutIdentifier(let name):
            // **No reason to refuse the move.** The old access dates from the time before
            // ``ServerCredentials/serverID``; the sentence says that no check could be made here
            // and leaves the decision to the viewer.
            decision(
                title: "accounts.moveUnverified", name: name, continueKey: "accounts.moveConfirm")
        case .other(let name):
            differentServer(name)
        case .relocated(let count):
            done(count)
        }
    }

    private var input: some View {
        VStack(alignment: .leading, spacing: 18) {
            TextField(AppLanguageSetting.text("accounts.moveAddress"), text: $model.address)
                .keyboard(forItem: .address)
                .remoteKeyboard($model.address, pending: focus == "adresse")
                .textFieldStyle(.plain)
                .font(TypeLevel.text.font)
                .frame(maxWidth: 700)
                .focused($focus, equals: "adresse")

            if case .error(let key) = model.finding {
                Text(appKey: key)
                    .font(TypeLevel.lowercased.font)
                    .foregroundStyle(ColorRole.live.color)
            }

            HStack(spacing: 18) {
                button("accounts.moveCheck", identifier: "pruefen", emphasized: true) {
                    Task { await model.verify() }
                }
                button("common.cancel", identifier: "abbrechen", emphasized: false, action: onCancel)
            }
        }
    }

    /// The decision about the move. **Its button is the consent**, even without a
    /// verifiable ID: this screen then shows the sentence "could not be verified" and below
    /// it the button — the "ask instead of guess" rule from
    /// ``Core/ServerMove``.
    private func decision(title: String, name: String, continueKey: String) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(appKey: title)
                .font(TypeLevel.footer.font)
                .foregroundStyle(ColorRole.text.color)
            Text(verbatim: name)
                .font(TypeLevel.lowercased.font)
                .foregroundStyle(ColorRole.textQuiet.color)

            HStack(spacing: 18) {
                button(continueKey, identifier: "umziehen", emphasized: true) {
                    if case .withoutIdentifier = model.finding { model.confirmWithoutID() }
                    model.adopt()
                    if case .relocated = model.finding { onDone() }
                }
                button("common.cancel", identifier: "abbrechen", emphasized: false) {
                    model.backToInput()
                }
            }
        }
    }

    /// **A different server is not an error message but a fork in the road.**
    ///
    /// It can be a mistyped address or really a second server. Neither
    /// leads here: a second server is set up via "Weiteres Konto",
    /// not via a move — otherwise the old one would lose its address.
    private func differentServer(_ name: String) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(app: "accounts.moveOtherServer")
                .font(TypeLevel.footer.font)
                .foregroundStyle(ColorRole.live.color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 900, alignment: .leading)
            Text(verbatim: name)
                .font(TypeLevel.lowercased.font)
                .foregroundStyle(ColorRole.textQuiet.color)

            button("accounts.moveBack", identifier: "zurueck", emphasized: true) {
                model.backToInput()
            }
        }
    }

    private func done(_ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            // The number is shown because a move can affect more than one account:
            // two people on the same server move together.
            Text(app: "accounts.moveDone \(count)")
                .font(TypeLevel.footer.font)
                .foregroundStyle(ColorRole.text.color)

            button("common.done", identifier: "fertig", emphasized: true, action: onCancel)
        }
    }

    private func button(
        _ key: String, identifier: String, emphasized: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(appKey: key)
                .font(TypeLevel.footer.font)
                .settingsFont(isFocused: focus == identifier, muted: !emphasized)
                .settingsSurface(.pill, isFocused: focus == identifier)
        }
        .bareFocusableButton()
        .focused($focus, equals: identifier)
    }
}
