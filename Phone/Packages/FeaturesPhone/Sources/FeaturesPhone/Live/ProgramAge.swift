import Core
import DesignSystemPhone
import Foundation
import PlaylistKit
import SwiftUI

/// How old the program is, and the way to refresh it.
///
/// **The button is the only way to the network that this area has** — and that is why it stands
/// here and not in an automatic.
///
/// **Re-measured on 2026-09-05, because the first reasoning was wrong.** There it said "over the
/// tunnel a process of minutes". The tunnel plays no role here, however: the provider
/// comes directly from the internet and not from the home — exactly the difference that the
/// state ``PlaybackPhase/networkXtream`` expressly names. Measured: **11.5 MB in 3.8
/// seconds.**
///
/// The button stays a button all the same. 11 MB is nothing on Wi-Fi and on cellular a
/// third of what an hour of frugal watching costs; and a reconciliation that starts on its own
/// on opening does so even if one only wanted to check briefly
/// which channel is on right now.
///
/// **The age is shown, not only the action.** "Refresh" alone leaves open
/// whether it is necessary; "from 2026-09-02, 22:14" answers the question before it is asked.
struct ProgramAge: View {

    let state: ProgrammeState
    let isRefreshing: Bool
    let fresh: () -> Void

    var body: some View {
        HStack(spacing: Metrics.targetSpacing) {
            Text(verbatim: text)
                .font(TypeLevel.label.font)
                .foregroundStyle(ColorRole.textQuiet.color)
                .lineLimit(1)

            Spacer(minLength: 0)

            Button(action: fresh) {
                if isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: Glyph.refresh.name)
                        .foregroundStyle(ColorRole.textMatt.color)
                }
            }
            .frame(width: Metrics.target, height: Metrics.target)
            .disabled(isRefreshing)
            .accessibilityLabel(Text(appKey: "live.refreshGuide"))
        }
        .padding(.leading, MetricsBoard.phone.margin)
        .padding(.trailing, MetricsBoard.phone.margin - (Metrics.target - 19) / 2)
    }

    /// **Two cases, two sentences.** "0 broadcasts" with a date in front would be
    /// information about a cache that does not exist.
    private var text: String {
        guard state.broadcasts > 0, let recent = state.recent else {
            return AppLanguageSetting.text("live.guideMissing")
        }
        // **The date only if it is not today.** "Program from 5 Sept. 2026, 23:56"
        // was cut off on screen, and half the sentence carried the information
        // that everyone has anyway: what day it is today. For a reconciliation from a moment ago
        // the time is the whole answer.
        let today = Calendar.current.isDateInToday(recent)
        let when =
            today
            ? recent.formatted(date: .omitted, time: .shortened)
            : recent.formatted(date: .abbreviated, time: .shortened)
        return String(
            format: AppLanguageSetting.text("live.guideAsOf %@ %@"),
            when, state.broadcasts.formatted(.number.grouping(.automatic)))
    }
}
