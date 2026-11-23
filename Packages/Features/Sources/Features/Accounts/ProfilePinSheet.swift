import Core
import DesignSystem
import Flows
import ParentalControls
import ProfileKit
import SwiftUI

/// The number pad in front of a protected profile — **with "Forgot PIN" as the third
/// button, and the same in every place** (AP45, 2026-09-25).
///
/// **The finding:** The way out per profile (``ProfileKit/PINFallback/Lock/profile(_:)``) had stood in the
/// switcher since 2026-09-24, while the management ("Manage profiles") knew **no** number pad
/// when switching to a protected profile — the press fizzled out, and whoever had forgotten the PIN
/// did not even get from there to the way out. Two places that each build their
/// own number pad drift apart in exactly this way; that is why it now exists once.
///
/// **Without an Apple account the third button stays away**, because without the cloud there is no waiting period
/// and no second device that confirms — ``offersEscape(cloud:)``.
struct ProfilePinSheet: View {

    let profile: Profile
    /// `nil` means: without the cloud, hence without a way out.
    let cloud: ProfileCloud?
    /// The typed PIN — `true` closes the sheet.
    let onSubmit: (String) -> Bool
    let onCancel: () -> Void
    /// The PIN has fallen via the way out; the caller closes and re-reads.
    let onUnlocked: () -> Void

    @State private var showsEscape = false
    /// The waiting period of this profile — **above the block and not behind the button**, the same
    /// rule as at ``PinDoorSheet`` (finding 6). Until C2 it was not here. Read via
    /// ``Flows/PinRecoveryFlow``, that is, after a sync (AP58 R2).
    @State private var deadline: PinRecoveryFlow?

    /// Whether the third button appears.
    nonisolated static func offersEscape(cloud available: Bool) -> Bool { available }

    var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()
            if showsEscape, let cloud {
                PinEscapeSheet(
                    cloud: cloud,
                    lock: .profile(profile.identifier),
                    onRelease: {
                        Self.releaseLock(
                            from: profile, cloud: cloud, keychain: SecureStore())
                        onUnlocked()
                    },
                    onClose: { showsEscape = false })
            } else {
                VStack(spacing: 22) {
                    PinDeadlineRow(state: deadline?.state ?? .none)
                    PinSheet(
                        reason: AppLanguageSetting.text("profiles.pinReason \(profile.name)"),
                        onSubmit: onSubmit,
                        onCancel: onCancel,
                        onForgot: Self.offersEscape(cloud: cloud != nil)
                            ? { showsEscape = true } : nil)
                }
            }
        }
        .task {
            if deadline == nil, let cloud {
                deadline = PinRecoveryFlow(cloud: cloud, lock: .profile(profile.identifier))
            }
            await deadline?.read()
        }
        .onChange(of: showsEscape) { _, _ in
            Task { await deadline?.read() }
        }
    }

    /// The PIN of this profile falls — **household-wide, and the request with it.**
    ///
    /// **The request has to go, not just the PIN.** If it stayed, the next PIN
    /// of this profile would come with a resolved waiting period from the start: Whoever sets it would have
    /// it open again at the same moment.
    ///
    /// **And the PIN falls in the cloud, not just here** (AP52): as a tombstone via
    /// ``ProfileKit/ProfilePINMaintenance/redeem(forItem:keychain:cloud:now:)``. Otherwise the
    /// next run would fetch it back from the zone, and on every other device it would stay in place.
    static func releaseLock(
        from profile: Profile, cloud: ProfileCloud?, keychain: any KeyValueStore
    ) {
        ProfilePINMaintenance.redeem(
            forItem: profile.identifier, keychain: keychain, cloud: cloud, now: Date())
    }
}
