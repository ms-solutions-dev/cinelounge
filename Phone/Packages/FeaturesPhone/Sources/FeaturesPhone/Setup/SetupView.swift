import Core
import DesignSystemPhone
import Flows
import SwiftUI

/// The phone's first setup — **a switch over ``Flows/SetupState`` and nothing more** (AP88 wave 6).
///
/// The order of the steps, the iCloud deadline and every "back" live in ``Flows/SetupJourney``,
/// the same as on the TV; a screen here only shows a state and sends an input. **The screens
/// follow the TV's A1 to A7 with the same keys**; where they differ, the hand is the reason: a
/// tap instead of the focus, a back arrow instead of the Menu button, the camera instead of a
/// code on screen.
///
/// **One column on the iPad** — the width of the settings pages (``ContentColumn``), so that a
/// row's name and its mark do not stand a screen apart.
public struct SetupView: View {

    let model: SetupModel
    private let done: () -> Void

    @Environment(\.horizontalSizeClass) private var widthClass

    /// - Parameter done: the shell adopts what was set up — called once, when the machine
    ///   reaches `finished`.
    public init(model: SetupModel, done: @escaping () -> Void = {}) {
        self.model = model
        self.done = done
    }

    public var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                if Self.hasBack(model.state) { SetupBackRow { model.send(.back) } }
                step
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                if case .welcome = model.state { SetupFooter() }
            }
            .contentColumn(widthClass)
        }
        .onChange(of: model.isFinished, initial: true) { _, finished in
            guard finished else { return }
            model.finish()
            done()
        }
    }

    /// Where the switch draws the back arrow — **everywhere the machine knows a way back.** A1 and
    /// A2 have none (§1.4 point 3), A7 leads back through its own row, and A5 draws its own: the
    /// sheet answers "back" first (from the password to the code), as the Menu button on the TV.
    nonisolated static func hasBack(_ state: Flows.SetupState) -> Bool {
        switch state {
        case .probing, .welcome, .finished, .done, .jellyfin: false
        case .fetchingFromPhone, .creating, .householdPin, .networkNotice, .sources, .channelList,
            .clServer:
            true
        }
    }

    @ViewBuilder
    private var step: some View {
        switch model.state {
        case .probing:
            SetupWaitView(skip: { model.send(.cloudDeadlinePassed) })
        case .welcome(let offer):
            SetupWelcomeView(offer: offer, send: model.send)
        case .fetchingFromPhone:
            SetupFetchView(model: model)
        case .creating(_, let lateCloudHint):
            SetupProfileStep(model: model, lateCloudHint: lateCloudHint)
        case .householdPin(let identifier):
            SetupPinStep(profile: model.profile(identifier), send: model.send)
        case .networkNotice:
            NetworkLawView(search: { model.send(.noticeAcknowledged) })
        case .sources(let page):
            SetupSourcesView(
                page: page, profile: model.profile(page.profile),
                copiedFrom: model.journey.machine.listsCopied(for: page.profile), send: model.send)
        case .jellyfin:
            SetupJellyfinView(model: model)
        case .channelList(let identifier):
            SetupChannelListStep(model: model, profile: model.profile(identifier))
        case .clServer:
            SetupClServerView(model: model)
        case .done(let summary):
            SetupDoneView(summary: summary, send: model.send)
        case .finished:
            Color.clear
        }
    }
}

/// The head of a step inside A3 to A6 — **"Lea · Jellyfin"**, the profile the sheet is for, as on
/// the TV (`SetupSheetFrame`).
struct SetupStepHead: View {

    let profile: SetupProfile?
    let source: String

    var body: some View {
        HStack(spacing: 10) {
            if let profile = profile?.profile {
                ProfileCircle(
                    letter: profile.initial, avatar: profile.avatar, edge: 28,
                    font: TypeLevel.label.font, letterColor: ColorRole.reason.color,
                    surface: ProfileColor.tag(profile.color.rawValue) ?? ColorRole.surfaceHigh.color)
            }
            Text(verbatim: Self.title(profile: profile, source: source))
                .font(TypeLevel.footer.font)
                .foregroundStyle(ColorRole.textMatt.color)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    nonisolated static func title(profile: SetupProfile?, source: String) -> String {
        guard let name = profile?.profile.name, !name.isEmpty else { return source }
        return "\(name) · \(source)"
    }
}

/// The back arrow of a setup step — **the counterpart of the TV's Menu button**, top left where
/// the navigation's back stands everywhere else in the app.
struct SetupBackRow: View {

    let action: () -> Void

    var body: some View {
        HStack {
            Button(action: action) {
                Image(systemName: Glyph.back.name)
                    .foregroundStyle(ColorRole.textMatt.color)
            }
            .frame(width: Metrics.target, height: Metrics.target)
            .accessibilityLabel(Text(app: "common.back"))
            Spacer()
        }
        .padding(.horizontal, MetricsBoard.phone.margin - (Metrics.target - 19) / 2)
    }
}

extension View {

    /// The loud or the quiet button style — **one call for the setup's rows of buttons**, whose
    /// first answer is loud and every other quiet.
    @ViewBuilder
    func setupButtonStyle(loud: Bool) -> some View {
        if loud {
            buttonStyle(.loud)
        } else {
            buttonStyle(.quiet)
        }
    }
}
