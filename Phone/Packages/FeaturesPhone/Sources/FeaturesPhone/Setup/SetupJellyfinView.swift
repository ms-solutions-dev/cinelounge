import Core
import DesignSystemPhone
import Flows
import JellyfinKit
import SwiftUI

/// A5 — **Jellyfin for the setup's profile, on the shared ``Flows/SetupJellyfinSheet``** (AP88 §2.8).
///
/// The same sheet as on the TV: the address from the profile and straight to Quick Connect
/// (`.confirm`), or the server search and the field (`.fresh`); "Choose another server" when the
/// profile's server does not answer; the question when Quick Connect signed in someone else. The
/// phone shows the same steps with its own building blocks — the field to type in is the cheap
/// path here, the code the second one.
///
/// **The back arrow is the sheet's** (``Flows/SetupJellyfinSheet/back()``): from the password to
/// the code first, then back to A4 — the TV's Menu button.
struct SetupJellyfinView: View {

    let model: SetupModel

    @State private var sheet: SetupJellyfinSheet

    init(model: SetupModel) {
        self.model = model
        _sheet = State(initialValue: model.jellyfinSheet())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SetupBackRow { Task { await sheet.back() } }
            SetupStepHead(profile: sheet.profile, source: "Jellyfin")
                .padding(.horizontal, MetricsBoard.phone.margin)
            content
        }
        .task { await sheet.begin() }
        .onDisappear { sheet.stop() }
        .sheet(
            item: Binding(
                get: { sheet.login.certificatePrompt }, set: { if $0 == nil { sheet.rejectCertificate() } })
        ) { query in
            ScrollView {
                if let known = query.known {
                    CertificateChangedSheet(
                        query: query, known: known,
                        trustAnyway: { Task { await sheet.trustCertificate() } },
                        cancel: { sheet.rejectCertificate() })
                } else {
                    CertificateSheet(
                        query: query,
                        trust: { Task { await sheet.trustCertificate() } },
                        reject: { sheet.rejectCertificate() })
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(MetricsBoard.phone.sheetRadius)
            .presentationBackground(ColorRole.surfaceHigh.color)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch sheet.step {
        case .connecting:
            SetupSheet(title: "setup.server.checking") {
                LoadingState(message: "setup.server.checking")
            }
        case .unreachable(let errorKey):
            unreachable(errorKey)
        case .chooseServer:
            ChooseServerStep(sheet: sheet)
        case .code(let session):
            code(session)
        case .noCode(let errorKey):
            noCode(errorKey)
        case .password:
            PasswordStep(sheet: sheet)
        case .otherUser(let signedIn, let expected):
            otherUser(signedIn: signedIn, expected: expected)
        }
    }

    // MARK: - Steps

    private func unreachable(_ errorKey: String?) -> some View {
        SetupSheet(
            title: "setup.jellyfin.chooseServer", explanation: "setup.jellyfin.unreachable", error: errorKey
        ) {
            VStack(spacing: MetricsBoard.phone.gutter) {
                button("setup.jellyfin.again", loud: true) { Task { await sheet.retry() } }
                button("setup.jellyfin.chooseServer") { Task { await sheet.chooseOtherServer() } }
            }
        }
    }

    private func code(_ session: QuickConnect.Session) -> some View {
        SetupSheet(
            title: "setup.jellyfin.confirmOn %@", explanation: "setup.jellyfin.enterCode",
            wording: AppLanguageSetting.text("setup.jellyfin.confirmOn \(sheet.serverName)")
        ) {
            VStack(alignment: .leading, spacing: MetricsBoard.phone.gutter) {
                Text(verbatim: session.groupedCode)
                    .iconSize(40, weight: .semibold, design: .monospaced)
                    .foregroundStyle(ColorRole.text.color)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, MetricsBoard.phone.section)
                    .background(
                        ColorRole.surface.color,
                        in: RoundedRectangle(cornerRadius: MetricsBoard.phone.fieldRadius)
                    )
                    .accessibilityLabel(Text(verbatim: session.code.map(String.init).joined(separator: " ")))
                if sheet.marksChildAccount { Footnote(message: "setup.jellyfin.childAccount") }
                button("setup.jellyfin.password") { sheet.choosePassword() }
                button("setup.jellyfin.newCode") { Task { await sheet.newCode() } }
                Footnote(message: "setup.code.footnote")
            }
        }
    }

    private func noCode(_ errorKey: String?) -> some View {
        SetupSheet(title: "setup.jellyfin.password", explanation: "setup.jellyfin.noCode", error: errorKey) {
            VStack(spacing: MetricsBoard.phone.gutter) {
                button("setup.jellyfin.password", loud: true) { sheet.choosePassword() }
                if sheet.login.canUseCode {
                    button("setup.jellyfin.newCode") { Task { await sheet.newCode() } }
                }
            }
        }
    }

    private func otherUser(signedIn: String, expected: String) -> some View {
        SetupSheet(
            title: "setup.jellyfin.otherUser %@ %@", explanation: "setup.jellyfin.otherUserHint",
            wording: AppLanguageSetting.text("setup.jellyfin.otherUser \(signedIn) \(expected)")
        ) {
            VStack(spacing: MetricsBoard.phone.gutter) {
                button(
                    AppLanguageSetting.text("setup.jellyfin.takeOver \(signedIn)"), loud: true, verbatim: true
                ) {
                    sheet.acceptOtherUser()
                }
                button("setup.jellyfin.again") { Task { await sheet.again() } }
            }
        }
    }

    private func button(
        _ key: String, loud: Bool = false, verbatim: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if verbatim { Text(verbatim: key) } else { Text(appKey: key) }
            }
            .frame(maxWidth: .infinity)
        }
        .setupButtonStyle(loud: loud)
    }
}

/// `.fresh` — **the servers the search found and the field**, the phone's cheap path.
private struct ChooseServerStep: View {

    @Bindable var sheet: SetupJellyfinSheet

    var body: some View {
        @Bindable var login = sheet.login
        SetupSheet(title: "setup.jellyfin.chooseServer", explanation: "setup.server.text", error: login.error)
        {
            VStack(alignment: .leading, spacing: MetricsBoard.phone.gutter) {
                ForEach(login.discoveries) { found in
                    DisclosureRow(
                        wording: found.name,
                        value: login.unreachable.contains(found.id)
                            ? AppLanguageSetting.text("login.serverUnreachable")
                            : found.address.host() ?? found.address.absoluteString,
                        isMissing: login.unreachable.contains(found.id)
                    ) {
                        Task { await sheet.select(found) }
                    }
                    .disabled(login.isRunning)
                }
                if login.isSearching {
                    LoadingState(message: "settings.portals.searching")
                }
                InputField(text: $login.address, placeholder: "setup.server.placeholder", kind: .address)
                if login.isRunning {
                    LoadingState(message: "setup.server.checking")
                } else {
                    Button {
                        Task { await sheet.connect() }
                    } label: {
                        Text(appKey: "setup.continue").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.loud)
                    .disabled(login.address.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Footnote(message: "setup.server.footnote")
            }
        }
    }
}

/// The password — **the user from the profile is filled in** (``Flows/SetupJellyfinSheet/choosePassword()``).
private struct PasswordStep: View {

    @Bindable var sheet: SetupJellyfinSheet

    var body: some View {
        @Bindable var login = sheet.login
        SetupSheet(title: "setup.password.title", explanation: "setup.password.text", error: login.error) {
            VStack(alignment: .leading, spacing: MetricsBoard.phone.gutter) {
                InputField(text: $login.user, placeholder: "common.username", kind: .name)
                InputField(text: $login.password, placeholder: "common.password", kind: .password)
                if login.isRunning {
                    LoadingState(message: "setup.password.signingIn")
                } else {
                    Button {
                        Task { await sheet.signIn() }
                    } label: {
                        Text(appKey: "common.signIn").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.loud)
                    .disabled(login.user.isEmpty)
                }
                Footnote(message: "setup.password.footnote")
            }
        }
    }
}
