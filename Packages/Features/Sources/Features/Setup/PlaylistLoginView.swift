import Core
import DesignSystem
import SwiftUI

/// What was entered on the TV for a channel list.
///
/// Deliberately raw strings and not checked values: Normalizing
/// an address lives in `XtreamEndpoint`, and it should stay there. If
/// a second version of it lived here, there would be two places where a provider
/// with an unusual address would have to get through — and only one would be tested.
///
/// **In `Features` since AP88 wave 4** — the setup's IPTV sheet (A4) shows the same form as the
/// retrofit in the app target.
nonisolated public struct PlaylistAccess: Equatable, Sendable {

    public enum Kind: String, CaseIterable, Identifiable, Sendable {
        case xtream
        case m3u

        public var id: String { rawValue }

        var titleKey: String {
            switch self {
            case .xtream: "settings.playlistKindXtream"
            case .m3u: "settings.playlistKindM3U"
            }
        }
    }

    public var kind: Kind = .xtream
    public var address = ""
    public var username = ""
    public var password = ""

    public init(kind: Kind = .xtream, address: String = "", username: String = "", password: String = "") {
        self.kind = kind
        self.address = address
        self.username = username
        self.password = password
    }
}

/// The path through a channel list: address, username, password.
///
/// **Here every field is an imposition.** On tvOS you type character by character
/// on an on-screen keyboard, there is no system-wide
/// clipboard, and a Xtream password is routinely twenty random
/// characters long. With the media server, QuickConnect spares the user that; here there
/// is nothing comparable. That is why only what cannot be guessed without the
/// provider appears here:
///
/// - The **name** is missing, although the settings carry it: It can be derived from the
///   host name and changed later.
/// - The **program guide** is missing: A Xtream account brings the broadcast times
///   with it, and with an M3U it can be retrofitted.
///
/// Under each field it says what belongs in it. Without these lines someone types their
/// email address into the username or the full channel address into the
/// server field, and the message afterwards reads "not reachable" — which masks the
/// actual error.
public struct PlaylistLoginView: View {

    /// Accepts the account and **checks it**. Returns a translation key
    /// if it is unusable, otherwise `nil`.
    ///
    /// The check belongs where the lists are managed, and not
    /// here: Only there is it known how an account is queried. It is reported back
    /// nonetheless — otherwise a mistyped server counts as set up, and
    /// the user afterwards sees an empty Live area and looks for the error in
    /// the app.
    let onSubmit: @MainActor (PlaylistAccess) async -> String?

    /// The way back. `nil` if there is none — from the choice between the two paths
    /// there is one; when retrofitting it leads back to the settings.
    let onCancel: (() -> Void)?

    /// The kinds on offer — **only M3U without a network** (AP88 §2.4): an Xtream account is
    /// checked at the provider's server before it is stored, and that check cannot answer
    /// offline. An M3U address is taken over without a fetch.
    let kinds: [PlaylistAccess.Kind]

    @State private var draft = PlaylistAccess()
    @State private var isChecking = false
    /// Translation key of the last failure, not the finished text.
    @State private var errorKey: String?
    @FocusState private var focus: String?

    public init(
        onSubmit: @escaping @MainActor (PlaylistAccess) async -> String?, onCancel: (() -> Void)?,
        kinds: [PlaylistAccess.Kind] = PlaylistAccess.Kind.allCases
    ) {
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        self.kinds = kinds.isEmpty ? PlaylistAccess.Kind.allCases : kinds
        _draft = State(initialValue: PlaylistAccess(kind: self.kinds[0]))
    }

    /// The kind the form shows — **the chosen one while it is on offer**, else the first that is.
    nonisolated static func kind(
        _ chosen: PlaylistAccess.Kind, among kinds: [PlaylistAccess.Kind]
    )
        -> PlaylistAccess.Kind
    {
        kinds.contains(chosen) ? chosen : kinds.first ?? chosen
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            header

            // The type first: It decides which fields appear at all, and
            // saves two inputs with an M3U.
            HStack(spacing: 14) {
                ForEach(kinds) { kind in
                    kindButton(kind)
                }
            }
            .onChange(of: kinds) { _, offered in
                draft.kind = Self.kind(draft.kind, among: offered)
            }

            field(
                "settings.playlistAddress",
                hint: draft.kind == .xtream ? "login.playlistServerHint" : "login.playlistM3UHint",
                text: $draft.address,
                id: "address"
            )

            if draft.kind == .xtream {
                field(
                    "common.username",
                    hint: "login.playlistUserHint",
                    text: $draft.username,
                    id: "user"
                )
                field(
                    "common.password",
                    hint: "login.playlistPasswordHint",
                    text: $draft.password,
                    id: "pass",
                    isSecret: true
                )
            }

            if let errorKey {
                // Names the cause instead of failing across the board — on a TV
                // nobody can look into logs.
                Label(
                    app: LocalizedStringKey(errorKey),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(TypeLevel.footer.font)
                .foregroundStyle(ColorRole.live.color)
            }

            footer
        }
        .frame(maxWidth: 900, alignment: .leading)
    }

    // MARK: - Header and footer

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(app: "login.playlistTitle")
                .font(TypeLevel.title.font)
                .foregroundStyle(ColorRole.text.color)

            // The hint about the phone keyboard stands here and not at a
            // single field: The system offers it by itself at the first field,
            // but only as a fleeting message — anyone who misses it types everything with
            // the remote.
            Text(app: "login.playlistIntro")
                .font(TypeLevel.text.font)
                .foregroundStyle(ColorRole.textMatt.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 12)
    }

    private var footer: some View {
        HStack(spacing: 18) {
            Button(action: submit) {
                HStack(spacing: 14) {
                    if isChecking { ProgressView() }
                    Text(app: isChecking ? "login.playlistChecking" : "login.playlistCheck")
                }
                .font(TypeLevel.header.font)
                .foregroundStyle(focus == "submit" ? ColorRole.text.color : ColorRole.reason.color)
                .padding(.horizontal, 54)
                .padding(.vertical, 20)
                .background(
                    focus == "submit" ? ColorRole.tag.color : ColorRole.text.color,
                    in: Capsule()
                )
            }
            .bareFocusableButton()
            .focused($focus, equals: "submit")
            .focusHighlight(
                focus == "submit",
                scale: Tokens.Focus.buttonScale,
                accent: ColorRole.brandLight.color
            )

            if let onCancel {
                Button(action: onCancel) {
                    Text(app: "common.back")
                        .font(TypeLevel.footer.font)
                        .foregroundStyle(ColorRole.textMatt.color)
                        .padding(.horizontal, 34)
                        .padding(.vertical, 16)
                }
                .bareFocusableButton()
                .focused($focus, equals: "cancel")
                .focusHighlight(
                    focus == "cancel",
                    scale: Tokens.Focus.buttonScale,
                    accent: ColorRole.brandLight.color
                )
            }
        }
        .padding(.top, 10)
    }

    // MARK: - Bausteine

    private func kindButton(_ kind: PlaylistAccess.Kind) -> some View {
        let isActive = draft.kind == kind
        let id = "kind-" + kind.id

        return Button {
            draft.kind = kind
            errorKey = nil
        } label: {
            Text(appKey: kind.titleKey)
                .font(TypeLevel.footer.font)
                .foregroundStyle(
                    focus == id
                        ? ColorRole.reason.color
                        : (isActive ? ColorRole.text.color : ColorRole.textMatt.color)
                )
                .padding(.horizontal, 30)
                .padding(.vertical, 15)
                .background(
                    focus == id
                        ? ColorRole.text.color
                        : (isActive ? ColorRole.text.color.opacity(0.14) : ColorRole.surface.color),
                    in: Capsule()
                )
        }
        .bareFocusableButton()
        .focused($focus, equals: id)
    }

    private func field(
        _ titleKey: String,
        hint hintKey: String,
        text: Binding<String>,
        id: String,
        isSecret: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(appKey: titleKey)
                .font(TypeLevel.lowercased.font)
                .foregroundStyle(ColorRole.textMatt.color)

            Group {
                // **The label belongs in the placeholder, not only next to it.**
                // As soon as a field gets focus, tvOS lays a keyboard screen of its own
                // over the whole view — the label above it
                // is then covered, as is the explanatory sentence below. What
                // appears at the top is the field's placeholder alone. Here there was an
                // empty string; so one typed blindly, without seeing which
                // field is meant and what is already in it. With a
                // Xtream password of twenty random characters that is intolerable.
                if isSecret {
                    SecureField(AppLanguageSetting.message(titleKey), text: text)
                        .remoteKeyboard(text, pending: focus == id, isSecret: true)
                } else {
                    // A provider's address is not prose: A capital letter
                    // at the start makes it unusable, and the error is hardly visible on the
                    // TV. Since AP24 that is no longer two
                    // modifiers here, but **one** line that says what belongs in
                    // the field — see ``DesignSystem/InputKind``.
                    TextField(AppLanguageSetting.message(titleKey), text: text)
                        .keyboard(forItem: .address)
                        .remoteKeyboard(text, pending: focus == id)
                }
            }
            .font(TypeLevel.header.font)
            .padding(.horizontal, 26)
            .padding(.vertical, 12)
            .background(ColorRole.surface.color, in: Capsule())
            .focused($focus, equals: id)
            .focusHighlight(focus == id, scale: 1, accent: ColorRole.brandLight.color)

            Text(appKey: hintKey)
                .font(TypeLevel.lowercased.font)
                .foregroundStyle(ColorRole.textQuiet.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Absenden

    /// Checks only for completeness and passes the rest on.
    ///
    /// Deliberately no address check at this point: It lives in
    /// `XtreamEndpoint`, and a second version here would be the stricter of the two
    /// with every unusual provider — it would reject an account that
    /// works.
    @MainActor
    private func submit() {
        // A second press during the check is caught here and not
        // through `.disabled` on the button: A disabled button loses focus on tvOS,
        // and the focus then wanders somewhere — after the check it would
        // no longer be where the user left it.
        guard !isChecking else { return }

        let trimmedAddress = draft.address.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedAddress.isEmpty else {
            errorKey = "settings.playlistBadAddress"
            return
        }
        if draft.kind == .xtream, draft.username.isEmpty || draft.password.isEmpty {
            errorKey = "settings.playlistBadXtream"
            return
        }

        var access = draft
        access.address = trimmedAddress
        // The username is trimmed, the password is not: The on-screen keyboard
        // likes to append a space when confirming, and a password may
        // contain some. A silently trimmed password would yield a
        // rejection whose cause nobody sees.
        access.username = access.username.trimmingCharacters(in: .whitespacesAndNewlines)

        errorKey = nil
        isChecking = true

        Task {
            let failure = await onSubmit(access)
            isChecking = false
            errorKey = failure
            // Clear only on success: After a rejection the typed text should
            // stay, otherwise the user starts over.
            if failure == nil { draft = PlaylistAccess(kind: draft.kind) }
        }
    }
}
