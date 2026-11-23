import Core
import DesignSystem
import Flows
import ParentalControls
import ProfileKit
import SwiftUI

/// The locked door including the way out — **one sheet for all three places that show it**
/// (AP43, 2026-09-23).
///
/// **Until here the same call stood three times:** in ``ParentalControlsDoor``, in
/// `AccountSettings` and in `SettingsView`. All three draw the same thing — the
/// number pad via ``ParentalControlsState``. Building the way out in three places
/// would mean forgetting it in one at the next screen; and the one where it
/// is missing is the one where someone stands in front of the locked door.
///
/// **The running waiting period stands above the block and not behind the button.** Whoever knows
/// the PIN opens the sheet and types — they would never think of looking under "Forgot PIN".
/// A reset that was only visible there would be noticed by the parent
/// only once it has gone through. The reasoning as a whole is at ``PinEscapeSheet``.
///
/// **Without the cloud no third button.** The way out hangs on the Apple account; without one it would be
/// a button that leads to a sheet that can do nothing. On the phone the
/// path via the account password at Jellyfin remains alongside — it needs no iCloud.
struct PinDoorSheet: View {

    @ObservedObject var lock: ParentalControlsState

    /// The cloud — `nil` means: no way out via the Apple account.
    var cloud: ProfileCloud? = ProfileCloud.attached

    /// The waiting period of the parental controls — read via ``Flows/PinRecoveryFlow``, that is,
    /// after a sync (AP58 R2).
    @State private var deadline: PinRecoveryFlow?
    @State private var showsEscape = false
    /// The open requests of the **profile** PINs (finding 6) — here only for information; the
    /// button to cancel is under "Forgot PIN" and in the parental controls, not
    /// above the number pad, where it would pull focus away from the block.
    @State private var escapes = ProfileEscapes.none

    var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()

            VStack(spacing: 22) {
                PinDeadlineRow(state: deadline?.state ?? .none)
                ProfileEscapeRows(escapes: escapes)
                PinSheet(
                    reason: lock.openQuestion.flatMap(lock.reason(forItem:)),
                    onSubmit: { lock.verify($0) },
                    onCancel: { lock.cancel() },
                    onForgot: cloud == nil ? nil : { showsEscape = true }
                )
            }
        }
        .task { await read() }
        // **A screen of its own and no switching within the sheet.** The way out replaces
        // the number pad instead of standing in its place: It scrolls, it has its own
        // sections, and it shares no axis with the block. The check
        // `noNestedScrollArea` reads off precisely from this that a scroll area
        // is allowed here — a sheet within the sheet would not have recognized it.
        #if os(tvOS)
            .fullScreenCover(isPresented: $showsEscape) {
                if let cloud {
                    PinEscapeSheet(
                        cloud: cloud,
                        // **The parental controls**: This sheet is the door in front of them
                        // (``ParentalControlsState``), not that of a profile.
                        lock: .parentalControls,
                        onRelease: redeem,
                        onClose: {
                            showsEscape = false
                            Task { await read() }
                        })
                }
            }
        #endif
    }

    private func read() async {
        if deadline == nil, let cloud {
            deadline = PinRecoveryFlow(cloud: cloud, lock: .parentalControls)
        }
        await deadline?.read()
        escapes = ProfileEscapes.read(
            cloud: cloud, profile: ProfileBook.read(from: FileStore()).profile)
    }

    /// The waiting period is over or a second device has confirmed — **the PIN falls.**
    ///
    /// **Deleted and not set anew.** Whoever arrives here does not know the old one; demanding a new
    /// one from them now would mean holding them between number pad and lock.
    /// The parental controls stand open afterwards, and that is the honest
    /// consequence of a reset — whoever wants them again sets them anew in the
    /// settings.
    private func redeem() {
        lock.clearPin()
        showsEscape = false
        lock.cancel()
    }
}
