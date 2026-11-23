import Core
import DesignSystem
import Flows
import SwiftUI

/// The notice before the first home-network search — **break point 8: no system question
/// without a word before it** (AP88 §2.5).
///
/// tvOS asks "Local Network" exactly once, at the first Bonjour call, and a "no" can afterwards
/// only be taken back in the system settings. Whoever meets that question unannounced in the
/// middle of a setup says no. The phone has had its own step for it since AP25
/// (`NetworkLawView`); the TV gets the same thought in its own sentences (GESTALTUNG §3).
///
/// **Once per installation and only before a search** — the machine decides when
/// (``Flows/SetupState/networkNotice(then:open:)``): only IPTV never meets it. "Continue" is the
/// only target; the Menu button leads back to where the press came from.
struct NetworkNoticeView: View {

    let send: (SetupInput) -> Void

    @FocusState private var focus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            Spacer(minLength: 0)
            SetupWordmark()
                .padding(.bottom, 10)
            Text(app: "setup.notice.title")
                .font(TypeLevel.section.font)
                .foregroundStyle(ColorRole.text.color)
            SetupNote(text: Text(app: "setup.notice.text"))
            Text(app: "setup.notice.later")
                .font(TypeLevel.lowercased.font)
                .foregroundStyle(ColorRole.textQuiet.color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 1100, alignment: .leading)
            SetupButton(title: "setup.continue", rank: .main, identifier: "continue", focus: $focus) {
                send(.noticeAcknowledged)
            }
            .padding(.top, 20)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, MetricsBoard.tv.margin)
        .padding(.vertical, TVMetrics.topMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .onAppear { focus = "continue" }
        .onExitCommand { send(.back) }
    }
}
