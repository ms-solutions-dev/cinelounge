import DesignSystemPhone
import Flows
import PortalKit
import SwiftUI

/// **Asking to be admitted — from the phone too** (decision 27, B7).
///
/// Until 2026-09-26 only the TV could make a join request; the phone
/// knew invitation, pairing code and PIN. The flow is the same
/// (``Flows/JoinRequester``): name and color come from the active profile, the
/// administrator decides on the role, and as long as this screen is open, it
/// polls for an answer.
struct JoinRequest: View {

    let model: PortalSettingsModel

    var body: some View {
        SettingsCard(header: "settings.portals.joinAsk") {
            VStack(alignment: .leading, spacing: MetricsBoard.phone.gutter) {
                outcome

                if model.requestState.waiting {
                    Button {
                        model.withdrawRequest()
                    } label: {
                        Text(app: "settings.portals.joinCancel").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.quiet)
                } else {
                    Button {
                        Task { await model.requestAdmission() }
                    } label: {
                        Text(
                            appKey: model.asks
                                ? "settings.portals.joinRequesting" : "settings.portals.joinRequest"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.loud)
                    .disabled(model.asks || model.requestingProfile == nil)
                }
            }
            .padding(Metrics.cardInset)
        }
        .padding(.bottom, MetricsBoard.phone.section)
    }

    /// Exactly one sentence per situation — the same ones as on the TV.
    @ViewBuilder
    private var outcome: some View {
        Group {
            switch model.requestState {
            case .none:
                if let profile = model.requestingProfile {
                    Text(app: "settings.portals.joinHint \(profile.name)")
                        .foregroundStyle(ColorRole.textMatt.color)
                } else {
                    Text(app: "settings.portals.joinNoProfile")
                        .foregroundStyle(ColorRole.textMatt.color)
                }
            case .waiting:
                Text(app: "settings.portals.joinWaiting")
                    .foregroundStyle(ColorRole.textMatt.color)
            case .throttled(let seconds):
                if let seconds {
                    Text(app: "settings.portals.joinThrottled \((seconds + 59) / 60)")
                        .foregroundStyle(ColorRole.progress.color)
                } else {
                    Text(app: "settings.portals.joinThrottledSoon")
                        .foregroundStyle(ColorRole.progress.color)
                }
            case .approved(let name, let withTag):
                Text(
                    app: withTag
                        ? "settings.portals.joinApproved \(name)"
                        : "settings.portals.joinApprovedNoMark \(name)"
                )
                .foregroundStyle(ColorRole.success.color)
            case .rejected:
                Text(app: "settings.portals.joinDeclined")
                    .foregroundStyle(ColorRole.progress.color)
            case .expired:
                Text(app: "settings.portals.joinExpired")
                    .foregroundStyle(ColorRole.progress.color)
            case .failed(let message):
                Text(verbatim: message)
                    .foregroundStyle(ColorRole.progress.color)
            case .notForChildren:
                Text(app: "settings.portals.joinNotForChildren")
                    .foregroundStyle(ColorRole.progress.color)
            }
        }
        .font(TypeLevel.label.font)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// **Approve or decline open requests — from the phone too** (decision 27, B7).
///
/// For administrators only (``Flows/ApprovalRule/isVisible(_:)``). Approving requires a
/// role and your own PIN; there is no default. An administrator gets their own
/// PIN for the console, and a name is only asked for when the server reports "exists already"
/// — as on the TV.
struct JoinApproval: View {

    let model: JoinApprovalModel

    @State private var pending: OpenRequest?
    @State private var role: RoleOption?
    /// The console on top of the role (AP85 #73) — off until switched on.
    @State private var console = false
    @State private var pin = ""
    @State private var ownPin = ""
    @State private var newName = ""

    var body: some View {
        SettingsCard(header: "settings.portals.joins") {
            VStack(alignment: .leading, spacing: 0) {
                if model.requestJoin.isEmpty {
                    Footnote(
                        message: model.isLoading
                            ? "settings.portals.joinsLoading" : "settings.portals.joinsNone")
                }
                ForEach(Array(model.requestJoin.enumerated()), id: \.element.id) { slot, request in
                    if slot > 0 { Separator() }
                    ChoiceRow(
                        name: request.name, subRow: request.device,
                        chosen: pending?.id == request.id
                    ) {
                        select(request)
                    }
                    if pending?.id == request.id {
                        decision(request)
                    }
                }
                if let rejection = model.rejection {
                    HintRow(
                        icon: Glyph.offline.name, color: ColorRole.progress.color,
                        title: "settings.portals.joins", wording: rejection)
                }
            }
        }
        .padding(.bottom, MetricsBoard.phone.section)
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

    private func decision(_ request: OpenRequest) -> some View {
        VStack(alignment: .leading, spacing: MetricsBoard.phone.gutter) {
            Text(
                app:
                    "settings.portals.joinFrom \(request.origin) \(request.asked.formatted(date: .abbreviated, time: .shortened))"
            )
            .font(TypeLevel.label.font)
            .foregroundStyle(ColorRole.textMatt.color)

            // **The household's real roles** (variant A, Max 2026-11-09) — as on the TV.
            Picker(selection: $role) {
                ForEach(model.roleOptions) { option in
                    roleLabel(option).tag(Optional(option))
                }
            } label: {
                Text(app: "settings.portals.joinRole")
            }
            .pickerStyle(.segmented)
            .onChange(of: role) { _, chosen in
                if !ApprovalRule.offersConsole(chosen) { console = false }
            }

            if let role {
                Footnote(message: role.explanation)
            }

            if ApprovalRule.offersConsole(role) {
                Toggle(isOn: $console) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app: "settings.portals.joinConsole")
                        Text(app: "settings.portals.joinConsoleHint")
                            .font(TypeLevel.label.font)
                            .foregroundStyle(ColorRole.textMatt.color)
                    }
                }
                .accessibilityIdentifier("join-console")
            }

            InputField(text: $pin, placeholder: "settings.portals.joinPin", kind: .password)
            if console {
                InputField(
                    text: $ownPin, placeholder: "settings.portals.joinOwnPin", kind: .password)
            }
            if model.rejectionCode == "household.person_exists" {
                InputField(text: $newName, placeholder: "settings.portals.joinName", kind: .name)
            }

            HStack(spacing: MetricsBoard.phone.gutter) {
                Button {
                    approve(request)
                } label: {
                    Text(app: "settings.portals.joinApprove").frame(maxWidth: .infinity)
                }
                .buttonStyle(.loud)
                .disabled(
                    model.isWorking || !ApprovalRule.ready(role, console: console, pin: pin, ownPin: ownPin))

                Button {
                    Task { if await model.reject(request) { pending = nil } }
                } label: {
                    Text(app: "settings.portals.joinDecline").frame(maxWidth: .infinity)
                }
                .buttonStyle(.quiet)
                .disabled(model.isWorking)
            }
        }
        .padding(Metrics.cardInset)
    }

    /// A server role by its name, "18+" along — the old two by their language key.
    private func roleLabel(_ option: RoleOption) -> Text {
        guard let name = option.name else { return Text(appKey: option.titleKey) }
        return Text(verbatim: option.adult ? "\(name) · 18+" : name)
    }

    private func approve(_ request: OpenRequest) {
        guard let chosen = ApprovalRule.role(role, console: console, ownPin: ownPin) else { return }
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            if await model.approve(
                request, als: chosen, pin: pin, newName: name.isEmpty ? nil : name)
            {
                pending = nil
            }
            // The PIN never stays displayed longer than necessary.
            pin = ""
            ownPin = ""
        }
    }
}
