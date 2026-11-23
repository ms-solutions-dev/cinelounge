import Core
import DesignSystem
import Flows
import ProfileKit
import SwiftUI

/// A2 — **"Who's watching here?"**: the profiles iCloud brought, "New profile", and the way
/// from the iPhone with its code already showing (AP88 §2, variant A with the QR from B).
///
/// **The machine owns the focus** (``Flows/WelcomeOffer/focus``): a late iCloud answer adds cards
/// but keeps the focus where it stands, so that nobody picks the wrong profile because the cards
/// jumped under the thumb (§2.6). This view only reports where the focus went.
///
/// **A child from iCloud stands greyed out** as long as this device has no household PIN
/// (decision of 2026-11-15 on question 2), with the quiet sentence "Choose an adult profile
/// first". The PIN does not travel through iCloud.
///
/// **The code needs no press** (§4.2): it shows from the start, the journey renews it before it
/// expires and keeps only one valid at a time. It is not focusable — the button next to it is the
/// way for whoever wants the long explanation.
///
/// **No catch on the Menu button:** "back" from A2 does nothing in the machine, and the system
/// sends the app to the background, like every tvOS app.
struct WelcomeView: View {

    let offer: WelcomeOffer
    /// The text of the QR code — `nil` while none is valid.
    let code: String?
    let languages: LanguageSelection
    let send: (SetupInput) -> Void

    @FocusState private var focus: String?
    @State private var chosenLanguage: String?
    @State private var isPairingRemote = false
    @State private var showsDiagnostics = false
    @FocusState private var diagnosticsFocus: String?

    nonisolated static let newProfileID = "neu"
    nonisolated static let fetchID = "holen"

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 30) {
                SetupWordmark()
                    .padding(.bottom, 10)
                Text(app: "setup.welcome.title")
                    .font(TypeLevel.section.font)
                    .foregroundStyle(ColorRole.text.color)
                Text(appKey: Self.subtitle(for: offer))
                    .font(TypeLevel.text.font)
                    .foregroundStyle(ColorRole.textMatt.color)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 1100)
                cards
                    .padding(.top, 30)
                if offer.asksForAdultFirst {
                    Text(app: "setup.welcome.adultFirst")
                        .font(TypeLevel.lowercased.font)
                        .foregroundStyle(ColorRole.textQuiet.color)
                }
                fetchRow
                    .padding(.top, 20)
            }
            .focusSection()
            Spacer(minLength: 0)
            footer
                .focusSection()
        }
        .padding(.horizontal, MetricsBoard.tv.margin)
        .padding(.vertical, TVMetrics.topMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { focus = Self.focusID(offer.focus) }
        .onChange(of: focus) { _, fresh in
            if let target = Self.offerFocus(fresh) { send(.focusMoved(target)) }
        }
        .background(footerSheets)
    }

    /// The remote pairing and the diagnostics as full-screen covers — **the Menu button closes
    /// them by itself**, as on the old sign-in screen.
    @ViewBuilder
    private var footerSheets: some View {
        #if os(tvOS)
            Color.clear
                .fullScreenCover(isPresented: $isPairingRemote) {
                    RemotePairingView { isPairingRemote = false }
                }
                .fullScreenCover(isPresented: $showsDiagnostics) {
                    ZStack(alignment: .topLeading) {
                        ColorRole.reason.color.ignoresSafeArea()
                        DiagnosticsSettings(focus: $diagnosticsFocus, source: nil)
                            .padding(.horizontal, MetricsBoard.tv.margin)
                            .padding(.vertical, TVMetrics.topMargin)
                    }
                }
        #endif
    }

    // MARK: - The cards

    private var cards: some View {
        HStack(alignment: .top, spacing: 60) {
            ForEach(offer.cards, id: \.profile.id) { card in
                profileCard(card)
            }
            newProfileCard
        }
    }

    private func profileCard(_ card: WelcomeOffer.Card) -> some View {
        let profile = card.profile.profile
        let id = Self.focusID(.profile(profile.identifier))
        let hasFocus = focus == id
        return Button {
            send(.chose(profile.identifier))
        } label: {
            VStack(spacing: 18) {
                ProfileCircle(
                    letter: profile.initial,
                    avatar: profile.avatar,
                    edge: 180,
                    font: TypeLevel.title.font,
                    letterColor: hasFocus ? ColorRole.reason.color : ColorRole.text.color,
                    surface: hasFocus ? ColorRole.text.color : ProfileColor.tag(profile.color.rawValue),
                    frame: hasFocus ? ColorRole.text.color : nil
                )
                .scaleEffect(hasFocus ? 1.08 : 1)
                .animation(.easeOut(duration: 0.18), value: hasFocus)
                Text(verbatim: profile.name)
                    .font(TypeLevel.footer.font)
                    .foregroundStyle(hasFocus ? ColorRole.text.color : ColorRole.textMatt.color)
                    .lineLimit(1)
                if profile.kind == .kind {
                    Label {
                        Text(app: "profiles.child")
                    } icon: {
                        Image(systemName: Glyph.kind.name)
                    }
                    .font(TypeLevel.lowercased.font)
                    .foregroundStyle(ColorRole.textQuiet.color)
                }
            }
            .frame(width: 240)
            .opacity(card.selectable ? 1 : 0.4)
        }
        .bareFocusableButton()
        .focused($focus, equals: id)
        .disabled(!card.selectable)
        .info(Text(verbatim: profile.name))
    }

    private var newProfileCard: some View {
        let hasFocus = focus == Self.newProfileID
        return Button {
            send(.choseNew)
        } label: {
            VStack(spacing: 18) {
                Image(systemName: Glyph.add.name)
                    .font(.system(size: 64))
                    .foregroundStyle(hasFocus ? ColorRole.reason.color : ColorRole.textMatt.color)
                    .frame(width: 180, height: 180)
                    .background(hasFocus ? ColorRole.text.color : ColorRole.surface.color, in: Circle())
                    .scaleEffect(hasFocus ? 1.08 : 1)
                    .animation(.easeOut(duration: 0.18), value: hasFocus)
                Text(app: "setup.welcome.newProfile")
                    .font(TypeLevel.footer.font)
                    .foregroundStyle(hasFocus ? ColorRole.text.color : ColorRole.textMatt.color)
                    .lineLimit(1)
            }
            .frame(width: 240)
        }
        .bareFocusableButton()
        .focused($focus, equals: Self.newProfileID)
        .info(appKey: "setup.welcome.newProfile")
    }

    // MARK: - From the iPhone

    /// The button and, next to it, the code — **the code only with a network**
    /// (``Flows/WelcomeOffer/showsCode``): handoff and pairing both need one.
    private var fetchRow: some View {
        HStack(alignment: .center, spacing: 40) {
            Button {
                send(.choseFetchFromPhone)
            } label: {
                Label {
                    Text(app: "setup.welcome.fetchFromPhone")
                } icon: {
                    Image(systemName: Glyph.fetchProfile.name)
                }
                .font(TypeLevel.footer.font)
                .settingsFont(isFocused: focus == Self.fetchID)
                .settingsSurface(.pill, isFocused: focus == Self.fetchID)
            }
            .bareFocusableButton()
            .focused($focus, equals: Self.fetchID)
            .disabled(!offer.showsCode)

            if offer.showsCode, let code, let image = QRCode.image(for: code) {
                HStack(spacing: 20) {
                    image
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 150, height: 150)
                        .padding(12)
                        // systemfarbe: a QR is read by a camera and not by the eye — it needs the
                        // brightest border there is, in every color scheme.
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityHidden(true)
                    Text(app: "setup.welcome.codeHint")
                        .font(TypeLevel.lowercased.font)
                        .foregroundStyle(ColorRole.textQuiet.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 300, alignment: .leading)
                }
            }
        }
    }

    // MARK: - The footer

    /// Language, iPhone as remote and diagnostics — **with the focus surface of the settings**
    /// (T4): bare text with a glow could not be seen from three metres, and nobody knew where
    /// they stood.
    private var footer: some View {
        let current = chosenLanguage ?? languages.currentCode
        return HStack(spacing: 16) {
            ForEach(languages.available, id: \.code) { language in
                footerButton(id: "lang-" + language.code, highlighted: language.code == current) {
                    languages.select(language.code)
                    chosenLanguage = language.code
                } label: {
                    Text(verbatim: language.endonym)
                }
            }
            footerButton(id: "fernkopplung") {
                isPairingRemote = true
            } label: {
                Label {
                    Text(app: "remote.pair.button")
                } icon: {
                    Image(systemName: Glyph.codeForPhone.name)
                }
            }
            footerButton(id: "diagnostics") {
                showsDiagnostics = true
            } label: {
                Label {
                    Text(app: "settings.section.diagnostics")
                } icon: {
                    Image(systemName: "stethoscope")
                }
            }
        }
    }

    private func footerButton<Label: View>(
        id: String, highlighted: Bool = false, action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        let hasFocus = focus == id
        return Button(action: action) {
            label()
                .font(TypeLevel.footer.font)
                .settingsFont(isFocused: hasFocus, muted: !highlighted)
                .settingsSurface(.pill, isFocused: hasFocus, reason: .clear)
        }
        .bareFocusableButton()
        .focused($focus, equals: id)
    }

    // MARK: - Focus and wording

    nonisolated static func focusID(_ focus: WelcomeOffer.Focus) -> String {
        switch focus {
        case .newProfile: newProfileID
        case .profile(let identifier): "profil-" + identifier.rawValue
        }
    }

    /// The focus as the machine knows it — `nil` for the fetch button and the footer, which the
    /// machine does not track.
    nonisolated static func offerFocus(_ id: String?) -> WelcomeOffer.Focus? {
        guard let id else { return nil }
        if id == newProfileID { return .newProfile }
        guard id.hasPrefix("profil-") else { return nil }
        return .profile(Profile.Identifier(rawValue: String(id.dropFirst("profil-".count))))
    }

    /// The sentence under the title — **why the cards are there**, or what comes without them.
    ///
    /// "Your iCloud already has profiles" only when iCloud brought them; cards that were in the
    /// book before (an interrupted setup) get the plain sentence.
    nonisolated static func subtitle(for offer: WelcomeOffer) -> String {
        if !offer.cloud.profiles.isEmpty { return "setup.welcome.fromCloud" }
        return offer.cards.isEmpty ? "setup.welcome.fresh" : "setup.welcome.known"
    }
}
