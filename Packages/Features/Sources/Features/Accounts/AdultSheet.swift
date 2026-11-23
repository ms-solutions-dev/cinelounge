import Core
import DesignSystem
import ParentalControls
import SwiftUI

/// **Adult channels — both rules, as on the phone** (G3, finding C8).
///
/// Xtream knows `is_adult`, an M3U list does not; there only "hide without marking"
/// helps. The second switch stood only on the phone until G3. **A sheet of its own** for
/// the same reason as ``DeviceLockSheet``: The section stays under fifteen
/// focus targets, and both switches stand where their explanation stands.
struct AdultSheet: View {

    @Binding var live: LivePreferences
    @Binding var hidesUnlabeled: Bool
    let onClose: () -> Void

    @FocusState private var focus: String?

    var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SettingsHeader("childLock.adult", hint: "childLock.adultHint")

                    SwitchRow(
                        title: "childLock.adult.show",
                        on: Binding(
                            get: { live.showsAdultChannels },
                            set: { zeigen in
                                // **Read fresh, change, write back** — a held
                                // copy would write back the groups that were hidden back then.
                                var fresh = LivePreferences.load(from: ProfileStore.playback)
                                fresh.setShowsAdultChannels(zeigen)
                                fresh.save(to: ProfileStore.playback)
                                live = fresh
                            }),
                        identifier: "erwachsen", focus: $focus)

                    SwitchRow(
                        title: "childLock.adult.hideUnmarked", message: "childLock.adult.hideUnmarked.text",
                        on: Binding(
                            get: { hidesUnlabeled },
                            set: { fresh in
                                hidesUnlabeled = fresh
                                ChannelLock.write(hidesUnlabeled: fresh)
                            }),
                        identifier: "ungekennzeichnet", focus: $focus)
                }
                .frame(maxWidth: 1100, alignment: .leading)
                .padding(.horizontal, MetricsBoard.tv.margin)
                .padding(.vertical, TVMetrics.topMargin)
            }
        }
        .onAppear { focus = "erwachsen" }
        .onExitCommand(perform: onClose)
    }
}
