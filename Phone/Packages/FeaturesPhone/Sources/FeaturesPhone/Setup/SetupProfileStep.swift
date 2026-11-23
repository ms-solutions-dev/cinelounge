import Core
import DesignSystemPhone
import Flows
import ParentalControls
import ProfileKit
import SwiftUI

/// A3 — **a new profile: name, color and kind**, in the form "Who's watching?" uses as well
/// (``NewProfileView``), with the head of the setup (AP88 §3).
///
/// **The profile is stored on "Create profile"** (``Flows/ProfileManagement/save(_:existing:)``)
/// and only then reported to the machine (``Flows/SetupInput/draftSaved(_:)``), which makes it
/// active before its first source (§1.4 point 1) — the step that finding 1 was missing on this
/// phone. The back arrow stores nothing.
///
/// **A late iCloud answer does not close the form** (§2.6): a quiet row above it says that iCloud
/// holds profiles, and its button leads back to A2, where they stand as cards.
struct SetupProfileStep: View {

    let model: SetupModel
    let lateCloudHint: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(app: "setup.profile.head")
                .font(TypeLevel.label.font)
                .foregroundStyle(ColorRole.textMatt.color)
                .padding(.horizontal, MetricsBoard.phone.margin)
            if lateCloudHint { cloudHint }
            NewProfileView(
                existing: nil, suggestion: model.stores.management.nextColor, previousLimit: nil,
                isPinSet: ParentalControlsState().isPinSet, titleInContent: true, save: save)
        }
    }

    private var cloudHint: some View {
        HStack(spacing: MetricsBoard.phone.gutter) {
            Label {
                Text(app: "setup.profile.cloudHint")
            } icon: {
                Image(systemName: "icloud")
            }
            .font(TypeLevel.footer.font)
            .foregroundStyle(ColorRole.textMatt.color)
            Spacer(minLength: Metrics.targetSpacing)
            Button {
                model.send(.back)
            } label: {
                Text(app: "setup.profile.showCloud")
            }
            .buttonStyle(.quiet)
        }
        .padding(.horizontal, MetricsBoard.phone.margin)
        .padding(.top, MetricsBoard.phone.gutter)
    }

    private func save(_ draft: ProfileDraft) {
        guard let fresh = model.stores.management.save(draft, existing: nil),
            let profile = ProfileBook.read(from: model.stores.ledger).profile.first(where: {
                $0.identifier == fresh
            })
        else { return }
        model.send(.draftSaved(model.describe(profile)))
    }
}

/// A3K — **the household PIN before a child profile becomes active** (AP88 §2.3).
///
/// Without a household PIN a child profile can be left with two taps; the PIN is not skipped,
/// and there is no "later". It lies in this device's Keychain and never in iCloud. The back arrow
/// leads to A2 or A7 and leaves the child profile in the book (§1.4 point 2).
struct SetupPinStep: View {

    let profile: SetupProfile?
    let send: (SetupInput) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MetricsBoard.phone.gutter) {
            Text(verbatim: AppLanguageSetting.text("setup.pin.head \(profile?.profile.name ?? "")"))
                .font(TypeLevel.label.font)
                .foregroundStyle(ColorRole.textMatt.color)
            Text(app: "setup.pin.title")
                .font(TypeLevel.title.font)
                .foregroundStyle(ColorRole.text.color)
            Footnote(message: "setup.pin.text")
            PinSheet(
                job: .assignPin, verifies: { _ in false }, sets: Self.store,
                succeeded: { send(.householdPinSet) })
        }
        .padding(.horizontal, MetricsBoard.phone.margin)
        .padding(.top, MetricsBoard.phone.gutter)
    }

    /// The PIN typed the same twice — **reported to the machine only once it lies in the
    /// Keychain**, so that a failed store does not open a child profile without a door.
    private static func store(_ digits: String) -> Bool {
        let lock = ParentalControlsState()
        return lock.setPin(digits) && lock.isPinSet
    }
}
