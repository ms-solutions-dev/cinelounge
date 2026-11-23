import Core
import DesignSystem
import Flows
import ParentalControls
import ProfileKit
import SwiftUI

/// Setting, changing or removing the PIN of a profile — **on the TV, from "Manage
/// profiles"** (AP52, product decision 12 of 2026-09-25).
///
/// **Until here nobody could set a profile PIN.** Bolt, number pad and "Forgot
/// PIN" stood, but never took effect. This sheet is the missing beginning.
///
/// **The flow:**
/// - **No PIN:** four digits, twice (``PinSetSheet``).
/// - **One PIN:** first the choice "Change" or "Remove", then the old PIN — via
///   ``ProfilePinSheet``, that is, with "Forgot PIN" as the third button. Whoever no longer knows it
///   thus reaches the way out ``ProfileKit/PINFallback/Lock/profile(_:)``, and its release clears the
///   PIN household-wide (``ProfilePinSheet/releaseLock(from:cloud:keychain:)``).
///
/// **The door in front is ``door``** and sits at the call site (``ProfileView``) — reasoning
/// there.
struct ProfilePinManagement: View {

    /// The parental-controls door in front of every touch of a profile PIN.
    ///
    /// **Why a door in addition to the old PIN:** The old PIN proves whose profile it is
    /// — not that an adult is sitting in front. A child knows its own PIN.
    /// Without a door it would take it away (and open its profile to its siblings) or set
    /// one that locks the parents out for a day. **Setting and changing too**, not
    /// only removing: A child that assigns itself a PIN thereby locks its parents
    /// out of the profile whose limit they are responsible for.
    ///
    /// **It only asks when the parental controls apply** (``ParentalControls/ProtectionRule/requiresPin(forItem:)``);
    /// an adult on an open device gets through without the device PIN. And it applies
    /// to every active profile, not just children: If the device lock stands, the person in front of the
    /// TV in the children's room is in doubt a child.
    nonisolated static let door = "profilpin"

    let profile: Profile
    @ObservedObject var model: ProfileModel
    /// `nil` means: without the cloud, hence without a way out.
    let cloud: ProfileCloud?
    let onDone: () -> Void

    /// **The steps are driven by the shared flow** (``Flows/ProfilePinFlow``, AP58 R2) —
    /// the same as on the phone. Until then a state machine of its own stood here.
    @State private var flow: ProfilePinFlow
    @FocusState private var focus: String?

    init(
        profile: Profile, model: ProfileModel, cloud: ProfileCloud?, onDone: @escaping () -> Void
    ) {
        self.profile = profile
        self.model = model
        self.cloud = cloud
        self.onDone = onDone
        _flow = State(initialValue: model.pinFlow(forItem: profile, state: .maintain, cloud: cloud))
    }

    var body: some View {
        switch flow.step {
        case .choice:
            choice
        case .oldPinForChange, .oldPinForRemoval, .lock, .recovery:
            ProfilePinSheet(
                profile: profile, cloud: cloud,
                onSubmit: acceptOld(_:),
                onCancel: onDone,
                onUnlocked: onDone)
        case .fresh:
            PinSetSheet(
                catalogTitleKey: "pin.create",
                onDone: { fresh in
                    flow.set(fresh)
                    onDone()
                },
                onCancel: onDone)
        }
    }

    /// The old PIN — **if it is right, it continues; otherwise the block stays.**
    private func acceptOld(_ digits: String) -> Bool {
        switch flow.acceptOld(digits) {
        case .wrong: return false
        case .next: return true
        case .removed:
            onDone()
            return true
        }
    }

    private var choice: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()
            VStack(spacing: 30) {
                Text(app: "profiles.pinManage")
                    .font(TypeLevel.section.font)
                    .foregroundStyle(ColorRole.text.color)

                Text(app: "profiles.pinHint \(profile.name)")
                    .font(TypeLevel.text.font)
                    .foregroundStyle(ColorRole.textMatt.color)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 860)

                HStack(spacing: 18) {
                    FormButton(
                        title: "pin.change", rank: .main, identifier: "aendern",
                        focus: $focus
                    ) { flow.chooseChange() }
                    FormButton(
                        title: "profiles.pinRemove", rank: .beside, warning: true,
                        identifier: "entfernen", focus: $focus
                    ) { flow.chooseRemoval() }
                    FormButton(
                        title: "common.cancel", rank: .beside, identifier: "abbrechen",
                        focus: $focus, action: onDone)
                }
            }
            .padding(40)
        }
    }
}
