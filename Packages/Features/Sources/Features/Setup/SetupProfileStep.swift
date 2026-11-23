import Core
import DesignSystem
import Flows
import ParentalControls
import ProfileKit
import SwiftUI

/// A3 — **a new profile: name, kind, picture and color**, in the sheet that "Who is watching?"
/// uses as well (``ProfileSheet``), with the head of the setup (AP88 §3).
///
/// **The profile is stored on "Continue"** (``Flows/ProfileManagement/save(_:existing:)``) and only
/// then reported to the machine (``Flows/SetupInput/draftSaved(_:)``), which makes it active before
/// its first source (§1.4 point 1). "Back" stores nothing.
///
/// **A late iCloud answer does not close the sheet** (§2.6): a quiet line at the foot says that
/// iCloud holds profiles, and its button leads back to A2, where they stand as cards.
struct SetupProfileStep: View {

    let lateCloudHint: Bool
    let send: (SetupInput) -> Void
    /// A profile from the book as the machine wants it (``Flows/SetupWorld/describe(_:keychain:)``).
    let describe: (Profile) -> SetupProfile

    @State private var management = ProfileManagement()
    @FocusState private var hintFocus: Bool

    var body: some View {
        ProfileSheet(
            existing: nil,
            suggestion: management.nextColor,
            previousLimit: nil,
            onSave: save,
            onCancel: { send(.back) },
            isPinSet: AccountCreation.isPinSet(),
            setupHead: AppLanguageSetting.text("setup.profile.head")
        )
        .overlay(alignment: .bottomLeading) {
            if lateCloudHint { cloudHint }
        }
        .onExitCommand { send(.back) }
    }

    private var cloudHint: some View {
        HStack(spacing: 24) {
            Label {
                Text(app: "setup.profile.cloudHint")
            } icon: {
                Image(systemName: Glyph.cloudProfiles.name)
            }
            .font(TypeLevel.footer.font)
            .foregroundStyle(ColorRole.textMatt.color)
            Button {
                send(.back)
            } label: {
                Text(app: "setup.profile.showCloud")
                    .font(TypeLevel.footer.font)
                    .settingsFont(isFocused: hintFocus)
                    .settingsSurface(.pill, isFocused: hintFocus)
            }
            .bareFocusableButton()
            .focused($hintFocus)
        }
        .padding(.horizontal, MetricsBoard.tv.margin)
        .padding(.bottom, TVMetrics.topMargin)
    }

    private func save(
        name: String, color: Profile.ColorTag, kind: Profile.Kind, limit: AgeLimit?, avatar: String?
    ) {
        let draft = ProfileDraft(name: name, color: color, kind: kind, limit: limit, avatar: avatar)
        guard let fresh = management.save(draft, existing: nil),
            let profile = ProfileBook.read(from: FileStore()).profile.first(where: { $0.identifier == fresh })
        else { return }
        send(.draftSaved(describe(profile)))
    }
}

/// A3K — **the household PIN before a child profile becomes active** (AP88 §2.3).
///
/// Without a household PIN a child profile can be left with two presses; the PIN is not skipped,
/// and there is no "later". It lies in this device's Keychain (``ParentalControls/Pin``) and never in
/// iCloud. "Back" leads to A2 or A7 and leaves the child profile in the book (§1.4 point 2).
struct HouseholdPinStep: View {

    let profile: SetupProfile?
    let send: (SetupInput) -> Void

    @StateObject private var lock = ParentalControlsState()

    var body: some View {
        SetupSheetFrame(title: title, stage: .profile) {
            VStack(alignment: .leading, spacing: 20) {
                Text(app: "setup.pin.title")
                    .font(TypeLevel.section.font)
                    .foregroundStyle(ColorRole.text.color)
                SetupNote(text: Text(app: "setup.pin.text"))
                PinSheet(reason: nil, onSubmit: submit, onCancel: { send(.back) }, assigns: true)
                    .frame(maxWidth: .infinity)
            }
        }
        .onExitCommand { send(.back) }
    }

    private var title: String {
        AppLanguageSetting.text("setup.pin.head \(profile?.profile.name ?? "")")
    }

    /// The PIN typed the same twice — **reported to the machine only once it lies in the
    /// Keychain**, so that a failed store does not open a child profile without a door.
    private func submit(_ digits: String) -> Bool {
        lock.setPin(digits)
        guard AccountCreation.isPinSet() else { return false }
        send(.householdPinSet)
        return true
    }
}
