import Core
import DesignSystem
import Flows
import JellyfinKit
import ParentalControls
import SwiftUI

/// A5 — **Jellyfin for one profile: confirm what the profile knows, or choose a server.**
///
/// Design A of 2026-11-15: the address comes from the profile, the server search and the
/// method choice fall away, the code and the QR stand at once. Code and QR take no focus; the two
/// buttons are the only targets, and "Back" lies on the Menu button. The logic lives in
/// ``Flows/SetupJellyfinSheet`` on ``Flows/LoginFlow``; this view only draws its
/// ``Flows/SetupJellyfinSheet/Step``.
///
/// **Driven from outside:** the setup shows this view while the journey stands in
/// ``Flows/SetupState/jellyfin(_:_:)``; every way out is an input to the journey, and the view
/// disappears with the state.
public struct JellyfinConfirmView: View {

    @State private var sheet: SetupJellyfinSheet
    @FocusState private var focus: String?

    public init(sheet: SetupJellyfinSheet) {
        _sheet = State(initialValue: sheet)
    }

    /// The program's sheet — the device's identity, the address memory and the child-account
    /// markers of this device.
    public init(journey: SetupJourney) {
        self.init(
            sheet: SetupJellyfinSheet(
                journey: journey, deviceID: DeviceIdentity.id(), deviceName: DeviceName.thisDevice,
                memory: FileStore(), isChildAccount: { ChildAccountList().isChild($0) }))
    }

    public var body: some View {
        SetupSheetFrame(title: sheet.profile?.sheetTitle("Jellyfin") ?? "Jellyfin") {
            content
        }
        .task { await sheet.begin() }
        .onDisappear { sheet.stop() }
        .onExitCommand { Task { await sheet.back() } }
        .onChange(of: Self.focusTarget(sheet.step), initial: true) { _, target in focus = target }
        .confirmationDialog(
            Text(app: "cert.title"),
            isPresented: Binding(
                get: { sheet.login.certificatePrompt != nil },
                set: { if !$0, sheet.login.certificatePrompt != nil { sheet.rejectCertificate() } }),
            titleVisibility: .visible
        ) {
            Button {
                Task { await sheet.trustCertificate() }
            } label: {
                Text(app: "cert.trust")
            }
            Button(role: .cancel) {
                sheet.rejectCertificate()
            } label: {
                Text(app: "common.cancel")
            }
        } message: {
            Text(
                verbatim: AppLanguageSetting.text("cert.explain") + "\n\n"
                    + (sheet.login.certificatePrompt?.fingerprint.readable ?? "")
                    + (sheet.login.certificatePrompt?.known.map {
                        "\n\n" + AppLanguageSetting.text("cert.changed") + "\n" + $0.readable
                    } ?? ""))
        }
    }

    private func field(_ path: ReferenceWritableKeyPath<LoginFlow, String>) -> Binding<String> {
        Binding(get: { sheet.login[keyPath: path] }, set: { sheet.login[keyPath: path] = $0 })
    }

    /// Where the focus goes when a step appears — **the first button, never the code.**
    nonisolated static func focusTarget(_ step: SetupJellyfinSheet.Step) -> String? {
        switch step {
        case .connecting: nil
        case .unreachable: "retry"
        case .chooseServer: "address"
        case .code, .noCode: "password"
        case .password: "user"
        case .otherUser: "take-over"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch sheet.step {
        case .connecting: connecting
        case .unreachable(let key): unreachable(key)
        case .chooseServer: chooseServer
        case .code(let session): code(session)
        case .noCode(let key): noCode(key)
        case .password: password
        case .otherUser(let signedIn, let expected): otherUser(signedIn, expected)
        }
    }

    private var title: some View {
        Text(app: "setup.jellyfin.confirmOn \(sheet.serverName)")
            .font(TypeLevel.title.font)
            .foregroundStyle(ColorRole.text.color)
    }

    @ViewBuilder
    private var childAccountNote: some View {
        if sheet.marksChildAccount {
            Label {
                Text(app: "setup.jellyfin.childAccount")
            } icon: {
                Image(systemName: Glyph.kind.name)
            }
            .font(TypeLevel.footer.font)
            .foregroundStyle(ColorRole.brandLight.color)
        }
    }

    private var connecting: some View {
        HStack(spacing: 18) {
            ProgressView()
            Text(app: "login.connecting")
                .font(TypeLevel.text.font)
                .foregroundStyle(ColorRole.textMatt.color)
        }
    }

    // MARK: - The code

    private func code(_ session: QuickConnect.Session) -> some View {
        VStack(alignment: .leading, spacing: 40) {
            title
            HStack(alignment: .center, spacing: 80) {
                if let qr = QRCode.image(for: sheet.login.codeWebAddress) {
                    VStack(spacing: 16) {
                        qr
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 300, height: 300)
                            .padding(20)
                            .background(.white, in: RoundedRectangle(cornerRadius: 16))
                        Text(app: "setup.jellyfin.scan")
                            .font(TypeLevel.lowercased.font)
                            .foregroundStyle(ColorRole.textQuiet.color)
                    }
                    .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 18) {
                    SetupNote(text: Text(app: "setup.jellyfin.enterCode"))
                    // festeschrift: read off from three meters, larger than any step of the scale.
                    Text(verbatim: session.groupedCode)
                        .font(.system(size: 92, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .kerning(6)
                        .foregroundStyle(ColorRole.text.color)
                    countdown
                    HStack(spacing: 14) {
                        ProgressView()
                        Text(app: "login.waitingForApproval")
                            .font(TypeLevel.footer.font)
                            .foregroundStyle(ColorRole.textMatt.color)
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
            }
            childAccountNote
            Spacer(minLength: 0)
            HStack(spacing: 24) {
                SetupButton(title: "setup.jellyfin.password", identifier: "password", focus: $focus) {
                    sheet.choosePassword()
                }
                SetupButton(title: "login.otherServer", identifier: "other-server", focus: $focus) {
                    Task { await sheet.chooseOtherServer() }
                }
            }
        }
    }

    private var countdown: some View {
        HStack(spacing: 20) {
            ProgressView(value: Double(sheet.login.remainingSeconds), total: Double(LoginFlow.codeLifetime))
                .tint(ColorRole.brandLight.color)
                .frame(width: 360)
            Text(Duration.seconds(sheet.login.remainingSeconds).formatted(.time(pattern: .minuteSecond)))
                .font(TypeLevel.footer.font)
                .monospacedDigit()
                .foregroundStyle(
                    sheet.login.remainingSeconds < 30 ? ColorRole.live.color : ColorRole.textQuiet.color)
        }
    }

    private func noCode(_ key: String?) -> some View {
        VStack(alignment: .leading, spacing: 34) {
            title
            if let key {
                SetupErrorLine(text: Text(appKey: key))
            } else if !sheet.login.canUseCode {
                SetupNote(text: Text(app: "setup.jellyfin.noCode"))
            }
            childAccountNote
            Spacer(minLength: 0)
            HStack(spacing: 24) {
                SetupButton(
                    title: "setup.jellyfin.password", rank: .main, identifier: "password", focus: $focus
                ) {
                    sheet.choosePassword()
                }
                if sheet.login.canUseCode {
                    SetupButton(title: "setup.jellyfin.newCode", identifier: "new-code", focus: $focus) {
                        Task { await sheet.newCode() }
                    }
                }
                SetupButton(title: "login.otherServer", identifier: "other-server", focus: $focus) {
                    Task { await sheet.chooseOtherServer() }
                }
            }
        }
    }

    // MARK: - The profile's server does not answer

    private func unreachable(_ key: String?) -> some View {
        VStack(alignment: .leading, spacing: 34) {
            title
            SetupNote(text: Text(app: "setup.jellyfin.unreachable"))
            if let key { SetupErrorLine(text: Text(appKey: key)) }
            Spacer(minLength: 0)
            HStack(spacing: 24) {
                SetupButton(title: "common.retry", rank: .main, identifier: "retry", focus: $focus) {
                    Task { await sheet.retry() }
                }
                SetupButton(title: "login.otherServer", identifier: "other-server", focus: $focus) {
                    Task { await sheet.chooseOtherServer() }
                }
            }
        }
    }

    // MARK: - Password

    private var password: some View {
        VStack(alignment: .leading, spacing: 26) {
            title
            InputRow(
                title: "login.user", text: field(\.user), state: .inRow, kind: .identifier,
                identifier: "user", focus: $focus)
            InputRow(
                title: "common.password", text: field(\.password), state: .inRow, kind: .identifier,
                isHidden: true, identifier: "secret", focus: $focus)
            if let key = sheet.login.error { SetupErrorLine(text: Text(appKey: key)) }
            Spacer(minLength: 0)
            SetupButton(title: "common.signIn", rank: .main, identifier: "sign-in", focus: $focus) {
                Task { await sheet.signIn() }
            }
        }
    }

    // MARK: - A server chosen by hand

    private var chooseServer: some View {
        VStack(alignment: .leading, spacing: 30) {
            Text(app: "setup.jellyfin.chooseServer")
                .font(TypeLevel.title.font)
                .foregroundStyle(ColorRole.text.color)
            if sheet.login.isSearching {
                HStack(spacing: 18) {
                    ProgressView()
                    Text(app: "login.searching")
                        .font(TypeLevel.text.font)
                        .foregroundStyle(ColorRole.textMatt.color)
                }
            } else if !sheet.login.verifiedDiscoveries.isEmpty {
                Text(app: "login.foundServers")
                    .textCase(.uppercase)
                    .font(TypeLevel.footer.font)
                    .kerning(3)
                    .foregroundStyle(ColorRole.textQuiet.color)
                HStack(spacing: 20) {
                    ForEach(sheet.login.verifiedDiscoveries) { entry in
                        serverCard(entry)
                    }
                }
            }
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    InputRow(
                        title: "login.address", text: field(\.address), state: .alone, kind: .address,
                        identifier: "address", focus: $focus)
                    Text(app: "login.addressHint")
                        .font(TypeLevel.lowercased.font)
                        .foregroundStyle(ColorRole.textQuiet.color)
                }
                SetupButton(title: "login.connect", rank: .main, identifier: "connect", focus: $focus) {
                    Task { await sheet.connect() }
                }
            }
            if let key = sheet.login.error { SetupErrorLine(text: Text(appKey: key)) }
        }
    }

    private func serverCard(_ entry: ServerDiscovery.Reachability) -> some View {
        let found = entry.found
        let identifier = "server-" + found.id
        return Button {
            Task { await sheet.select(found) }
        } label: {
            VStack(spacing: 8) {
                Text(verbatim: found.name)
                    .font(TypeLevel.header.font)
                Text(verbatim: found.address.host() ?? "")
                    .font(TypeLevel.lowercased.font)
                    .foregroundStyle(ColorRole.textMatt.color)
                if !entry.reachable {
                    Label {
                        Text(app: "login.serverUnreachable")
                    } icon: {
                        Image(systemName: Glyph.warning.name)
                    }
                    .font(TypeLevel.lowercased.font)
                    .foregroundStyle(ColorRole.live.color)
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 26)
            .background(
                ColorRole.surfaceHigh.color,
                in: RoundedRectangle(cornerRadius: MetricsBoard.tv.fieldRadius, style: .continuous))
        }
        .bareFocusableButton()
        .focused($focus, equals: identifier)
        .focusHighlight(focus == identifier, accent: ColorRole.brandLight.color)
        .opacity(entry.reachable ? 1 : 0.72)
    }

    // MARK: - Someone else signed in

    private func otherUser(_ signedIn: String, _ expected: String) -> some View {
        VStack(alignment: .leading, spacing: 34) {
            Text(app: "setup.jellyfin.otherUser \(signedIn) \(expected)")
                .font(TypeLevel.title.font)
                .foregroundStyle(ColorRole.text.color)
                .fixedSize(horizontal: false, vertical: true)
            SetupNote(text: Text(app: "setup.jellyfin.otherUserHint"))
            Spacer(minLength: 0)
            HStack(spacing: 24) {
                SetupButton(
                    title: "setup.jellyfin.takeOver \(signedIn)", rank: .main, identifier: "take-over",
                    focus: $focus
                ) {
                    sheet.acceptOtherUser()
                }
                SetupButton(title: "setup.jellyfin.again", identifier: "again", focus: $focus) {
                    Task { await sheet.again() }
                }
            }
        }
    }
}
