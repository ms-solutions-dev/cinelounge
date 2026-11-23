import Core
import DesignSystem
import Flows
import PortalKit
import SwiftUI

/// The open requests — **approve with role and PIN, or decline** (AP47, second app row).
///
/// **Where it stands:** under Settings → Portals, at the own sign-in. The roadmap names
/// "Profile → Access → Portals"; on the TV this path does not exist — portal access is
/// managed here and only here, and a second place would be one where you would have to
/// search.
///
/// **Visible only with the right to pair devices, and never with a borrowed profile**
/// (``ApprovalRule/isVisible(_:)``) — the call site decides that before it builds this view
/// at all. The server checks the same again; the app should just not offer buttons that end
/// in `403`.
///
/// **The PIN is that of the approver**, not Face ID: the administrator's device attribute
/// never expires, so "the device is signed in" does not suffice to let a person into the
/// household. The server checks it with the five attempts of `/login`.
struct ApprovalList: View {

    let model: JoinApprovalModel
    let focus: FocusState<String?>.Binding

    /// The request currently being decided.
    @State private var pending: OpenRequest?
    /// **Without a default** — see ``Flows/ApprovalRule/role(_:console:ownPin:)``.
    @State private var role: RoleOption?
    /// The console on top of the role (AP85 #73) — off until switched on.
    @State private var console = false
    @State private var pin = ""
    @State private var ownPin = ""
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(app: "settings.portals.joins")
                .font(TypeLevel.header.font)
                .foregroundStyle(ColorRole.text.color)

            if model.requestJoin.isEmpty {
                Text(app: model.isLoading ? "settings.portals.joinsLoading" : "settings.portals.joinsNone")
                    .font(TypeLevel.lowercased.font)
                    .foregroundStyle(ColorRole.textQuiet.color)
            }

            ForEach(model.requestJoin) { request in
                DisclosureRow(
                    wording: request.name,
                    value: request.device,
                    card: CardSpec(
                        headerWording: request.name,
                        statementWording: request.device,
                        explanation: "settings.portals.joinsCardHint"),
                    identifier: "join-" + request.id,
                    focus: focus
                ) {
                    select(request)
                }
                if pending?.id == request.id {
                    decision(request)
                }
            }

            if let rejection = model.rejection {
                Text(verbatim: rejection)
                    .font(TypeLevel.lowercased.font)
                    .foregroundStyle(ColorRole.live.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 900, alignment: .leading)
            }
        }
        .frame(maxWidth: 900, alignment: .leading)
        .padding(.top, 30)
        .task { await model.load() }
    }

    private func select(_ request: OpenRequest) {
        guard pending?.id != request.id else {
            pending = nil
            return
        }
        pending = request
        role = nil
        console = false
        pin = ""
        ownPin = ""
        newName = ""
    }

    /// Who asks, from where, when — and the decision.
    private func decision(_ request: OpenRequest) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Circle()
                    .fill(ProfileColor.from(request.color) ?? ColorRole.textMatt.color)
                    .frame(width: 18, height: 18)
                // **The origin is shown too** — the only thing by which the administrator can tell "from
                // my network" from "from outside".
                Text(
                    app:
                        "settings.portals.joinFrom \(request.origin) \(request.asked.formatted(date: .abbreviated, time: .shortened))"
                )
                .font(TypeLevel.lowercased.font)
                .foregroundStyle(ColorRole.textMatt.color)
            }

            Text(app: "settings.portals.joinRole")
                .font(TypeLevel.footer.font)
                .foregroundStyle(ColorRole.textMatt.color)
            // **The household's real roles** (variant A, Max 2026-11-09): a row as before,
            // only no longer fixed to three. "18+" goes along in the name, because that is the
            // difference one must not overlook when approving.
            HStack(spacing: 16) {
                ForEach(model.roleOptions) { option in
                    ChoiceRow(
                        title: option.titleKey,
                        wording: option.name.map { option.adult ? "\($0) · 18+" : $0 },
                        chosen: role == option,
                        card: CardSpec(
                            header: "settings.portals.joinRole", statement: option.titleKey,
                            statementWording: option.name, explanation: option.explanation),
                        identifier: "join-role-" + option.id,
                        focus: focus
                    ) {
                        role = option
                        if !ApprovalRule.offersConsole(option) { console = false }
                    }
                }
            }

            if ApprovalRule.offersConsole(role) {
                SwitchRow(
                    title: "settings.portals.joinConsole",
                    on: $console,
                    card: CardSpec(
                        header: "settings.portals.joinConsole",
                        explanation: "settings.portals.joinConsoleHint"),
                    identifier: "join-console",
                    focus: focus)
            }

            InputRow(
                title: "settings.portals.joinPin", text: $pin, state: .inRow, kind: .identifier,
                isHidden: true, width: 320, identifier: "join-pin", focus: focus)

            if console {
                InputRow(
                    title: "settings.portals.joinOwnPin", text: $ownPin, state: .inRow,
                    kind: .identifier, isHidden: true, width: 320, identifier: "join-own-pin",
                    focus: focus)
            }

            // **Only after the rejection "exists already".** A name field from the start would mean
            // that every administrator thinks about a question that is almost never asked.
            if model.rejectionCode == "household.person_exists" {
                InputRow(
                    title: "settings.portals.joinName", text: $newName, state: .inRow,
                    kind: .prose, width: 520, identifier: "join-name", focus: focus)
            }

            HStack(spacing: 20) {
                FormButton(
                    title: "settings.portals.joinApprove",
                    state: model.isWorking
                        ? .isRunning
                        : (ApprovalRule.ready(role, console: console, pin: pin, ownPin: ownPin)
                            ? .ready : .locked),
                    rank: .main,
                    identifier: "join-approve",
                    focus: focus
                ) {
                    guard let chosen = ApprovalRule.role(role, console: console, ownPin: ownPin) else {
                        return
                    }
                    let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task {
                        if await model.approve(
                            request, als: chosen, pin: pin, newName: name.isEmpty ? nil : name)
                        {
                            pending = nil
                        }
                        // The PIN never stays up longer than necessary.
                        pin = ""
                        ownPin = ""
                    }
                }

                FormButton(
                    title: "settings.portals.joinDecline",
                    state: model.isWorking ? .isRunning : .ready,
                    rank: .beside,
                    warning: true,
                    identifier: "join-decline",
                    focus: focus
                ) {
                    Task {
                        if await model.reject(request) { pending = nil }
                    }
                }
            }
        }
        .padding(.leading, 24)
        .padding(.vertical, 10)
    }
}
