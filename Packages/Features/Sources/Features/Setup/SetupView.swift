import Core
import DesignSystem
import Flows
import ProfileKit
import SwiftUI

/// The first setup on the TV — **a switch over ``Flows/SetupState`` and nothing more** (AP88 §3).
///
/// The order of the steps, the iCloud deadline, the code renewal and every "back" live in
/// ``Flows/SetupJourney``; a screen here only shows a state and sends an input. A second
/// decision in a view would be the second logic beside the core that AP88 exists to avoid.
///
/// **Every step from A1 to A7 has its screen.** A retrofit from the settings
/// (``Flows/SetupMachine/Start/retrofit(_:_:)``) uses the same switch and only ever reaches the
/// notice and the three sheets.
public struct SetupView: View {

    let journey: SetupJourney
    let languages: LanguageSelection
    let cloud: ProfileCloud?
    /// A profile from the book as the machine wants it — with what only the Keychain knows
    /// (``Flows/SetupWorld/describe(_:keychain:)``).
    let describe: (Profile) -> SetupProfile
    /// Accepts and checks an IPTV access for the active profile — `PlaylistAccounts.accept`.
    let acceptChannelList: @MainActor (PlaylistAccess) async -> String?

    public init(
        journey: SetupJourney, languages: LanguageSelection, cloud: ProfileCloud?,
        describe: @escaping (Profile) -> SetupProfile,
        acceptChannelList: @escaping @MainActor (PlaylistAccess) async -> String?
    ) {
        self.journey = journey
        self.languages = languages
        self.cloud = cloud
        self.describe = describe
        self.acceptChannelList = acceptChannelList
    }

    public var body: some View {
        ZStack {
            SetupBackground()
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch journey.state {
        case .probing:
            CloudWaitView()
        case .welcome(let offer):
            WelcomeView(
                offer: offer, code: journey.pairingCode, languages: languages, send: journey.send)
        case .fetchingFromPhone(let mode):
            SetupFetchView(
                mode: mode, cloud: cloud,
                onArrival: { arrival in
                    guard let input = arrival.input(describe: describe) else { return }
                    journey.send(input)
                },
                onCancel: { journey.send(.back) })
        case .creating(_, let lateCloudHint):
            SetupProfileStep(lateCloudHint: lateCloudHint, send: journey.send, describe: describe)
        case .householdPin(let identifier):
            HouseholdPinStep(profile: journey.machine.setupProfile(identifier), send: journey.send)
        case .networkNotice:
            NetworkNoticeView(send: journey.send)
        case .sources(let page):
            SourcesView(
                page: page, profile: journey.machine.setupProfile(page.profile),
                copiedFrom: journey.machine.listsCopied(for: page.profile), send: journey.send)
        case .jellyfin:
            JellyfinConfirmView(journey: journey)
        case .channelList:
            ChannelListSheet(journey: journey, accept: acceptChannelList)
        case .clServer:
            ClServerJoinView(journey: journey)
        case .done(let summary):
            SetupDoneView(
                summary: summary, profile: journey.machine.setupProfile(summary.profile),
                copiedFrom: journey.machine.listsCopied(for: summary.profile), send: journey.send)
        case .finished:
            Color.clear
        }
    }
}

/// The ground of every setup page — **the warm glow of the old sign-in screen**, so that the
/// intro fades onto the same light.
struct SetupBackground: View {

    var body: some View {
        ZStack {
            ColorRole.reason.color
            RadialGradient(
                colors: [ColorRole.brandDeep.color.opacity(0.7), .clear],
                center: .center, startRadius: 0, endRadius: 900)
        }
        .ignoresSafeArea()
    }
}
