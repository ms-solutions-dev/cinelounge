import Core
import DesignSystemPhone
import SwiftUI

/// Where playback goes: this iPhone or the Apple TV.
///
/// **On the road the TV is dimmed, not gone.** It exists, after all — just not
/// reachable right now. Removing it would claim it does not exist, and
/// the next time you come home it would be back without explanation. The only exception to
/// the rule "what does not work is not shown", and it has a name: the reason stands
/// as a sentence below.
struct TargetSheet: View {

    let target: PlaybackDestination
    /// Whether the Apple TV is reachable on the same network.
    let isTVReachable: Bool
    let select: (PlaybackDestination) -> Void

    var body: some View {
        SheetFrame(title: "target.title") {
            ForEach(PlaybackDestination.allCases) { possible in
                let reachable = possible == .phone || isTVReachable
                ChoiceRow(
                    name: AppLanguageSetting.text(.init(possible.titleKey)),
                    icon: possible.icon,
                    chosen: possible == target
                ) {
                    guard reachable else { return }
                    select(possible)
                }
                .opacity(reachable ? 1 : 0.4)
                .disabled(!reachable)
            }

            if !isTVReachable {
                Footnote(message: "target.awayFromHome")
            }
        }
    }
}
