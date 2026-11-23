import Core
import DesignSystem
import ParentalControls
import SwiftUI

/// What appears when a locked title is opened **directly**.
///
/// **The filter from stage 2 filters lists — it does not filter paths.** Anyone who opens a title
/// via the Top Shelf item on the system Home Screen, via a deep link
/// (`cinelounge://item/…`) or via a remembered path gets past every list. The title would then
/// be nowhere to be seen and yet openable — the kind of gap that makes a lock implausible, because it
/// only has to be found once.
///
/// **There is no PIN entry here, and that is a decision.** The locked
/// doors in ``LockedDoors`` are actions — accounts, settings, the lock
/// itself — and a pass is right for those: A parent wants to do something briefly.
/// A **title** is not an action but content. A sheet that shows it anyway against a PIN would turn the age limit into an inconvenience; whoever wants to see it switches
/// the lock off — where that belongs, and knowing that they have done it.
///
/// **The title is named, not concealed.** It was already on the system
/// Home Screen or in a history; concealing it here would protect
/// nothing and make the screen inexplicable.
struct LockedDoorView: View {

    let title: MediaItem
    let onBack: () -> Void

    @FocusState private var focus: String?

    var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()

            VStack(spacing: 28) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 72))
                    .foregroundStyle(ColorRole.textQuiet.color)

                Text(app: "childLock.blockedTitle")
                    .font(TypeLevel.section.font)
                    .foregroundStyle(ColorRole.text.color)

                Text(verbatim: title.title)
                    .font(TypeLevel.text.font)
                    .foregroundStyle(ColorRole.textMatt.color)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 860)

                Text(app: "childLock.blockedExplain")
                    .font(TypeLevel.footer.font)
                    .foregroundStyle(ColorRole.textQuiet.color)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 860)

                Button(action: onBack) {
                    Text(app: "common.back")
                        .font(TypeLevel.footer.font)
                        .settingsFont(isFocused: focus == "zurueck")
                        .settingsSurface(.pill, isFocused: focus == "zurueck")
                }
                .bareFocusableButton()
                .focused($focus, equals: "zurueck")
            }
            .padding(50)
        }
    }
}
