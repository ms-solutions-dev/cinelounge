import DesignSystemPhone
import ProfileKit
import SwiftUI

/// An account row with a profile picture.
///
/// **A child account differs in shape, not in color.** A colored frame around the profile
/// picture would be the obvious solution and is none under deuteranopia: red
/// and olive are at 1.02 : 1 there. The child account therefore carries a **symbol** and
/// a word — the same rule that already carries the live state and the portal states.
struct AccountRow: View {

    /// **The inset comes from the environment and not from this file** (finding of
    /// 2026-09-09). The row stood with a hard-coded ``Styling/MetricsBoard/margin`` (20) even where
    /// it sits in a ``SettingsCard`` and ``Metrics/cardInset`` (14) would apply — in the
    /// account-switch sheet, three texts thereby started on three different edges: the
    /// card header at 24, "Child mode" at 34, the account name at 40.
    ///
    /// It was thus the one building block that the pass of 2026-09-07 overlooked —
    /// ``Zeileneinzug`` lists ten, not this one. On the background nothing changes:
    /// the environment's default is ``Styling/MetricsBoard/margin``.
    @Environment(\.rowInset) private var inset

    let account: Account
    /// The profile the account belongs to — **for image and color of the circle** (AP49).
    /// `nil` means: the letter on the muted surface as before.
    let profile: Profile?
    let signedIn: Bool
    /// Which commands lie behind the row — as keys. Empty means: none.
    var swipeMarks: [String] = []
    /// An open "forgot PIN" request for the profile of this account — `nil` means none.
    var pinEscape: PINFallback.State? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: MetricsBoard.phone.gutter) {
                // The checkmark keeps its place, even when it is not there.
                Image(systemName: Glyph.done.pair.outlined)
                    .foregroundStyle(signedIn ? ColorRole.brandLight.color : .clear)
                    // For the eye. The selection is reported via
                    // ``AccessibilityTraits/isSelected`` — see ``AppearanceView``.
                    .accessibilityHidden(true)

                profileImage

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: account.name)
                        .font(TypeLevel.text.font)
                        .foregroundStyle(ColorRole.text.color)
                    subRow
                    if let pinEscape, pinEscape.pending {
                        PinFallbackBadge(name: profile?.name ?? account.name, state: pinEscape)
                    }
                    if !swipeMarks.isEmpty {
                        SwipeMark(commands: swipeMarks)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, inset)
            .frame(minHeight: Metrics.choiceRow)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The same silent choice row as in ``AppearanceView`` — here it would otherwise read
        // "Button" for every account, and which one is signed in was told only by the checkmark.
        .accessibilityAddTraits(signedIn ? [.isSelected] : [])
    }

    private var profileImage: some View {
        ProfileCircle(
            letter: account.initial, avatar: profile?.avatar, edge: 34,
            font: TypeLevel.footer.font,
            letterColor: profileColor == nil ? ColorRole.text.color : ColorRole.reason.color,
            surface: profileColor ?? ColorRole.surfaceHigh.color)
    }

    /// The color of the profile — **`nil` without a profile or for an unknown flag.**
    private var profileColor: Color? {
        profile.flatMap { ProfileColor.tag($0.color.rawValue) }
    }

    @ViewBuilder
    private var subRow: some View {
        HStack(spacing: 6) {
            if account.kind {
                Image(systemName: Glyph.kind.name)
                    .font(TypeLevel.lowercased.font)
                Text(appKey: "accounts.child")
            } else {
                // **The host name and not the address** — the same rule as in
                // search: a name answers "which server", a string of digits does not.
                Text(verbatim: account.server.host() ?? "")
            }
        }
        .font(TypeLevel.label.font)
        .foregroundStyle(ColorRole.textQuiet.color)
        .lineLimit(1)
    }
}

/// "PIN is being reset · 23:12:04 left" — **the badge on a profile with an open
/// request** (second review, strand C, finding 6). Whoever looks in the account list should
/// see the request before looking for it in parental controls.
struct PinFallbackBadge: View {

    /// Whose PIN is being dropped — **the same sentence as on the TV** (AP58 closing step): one
    /// key with profile and device, not two versions per device.
    let name: String
    let state: PINFallback.State

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: Glyph.info.name)
            switch state {
            case .isRunning(let due, let device):
                Text(app: "profiles.pinResetRunning \(name) \(device)")
                Text(timerInterval: Date()...max(Date(), due), countsDown: true)
                    .monospacedDigit()
            case .due(let device), .confirmed(let device):
                Text(app: "profiles.pinResetReady \(name) \(device)")
            case .wartetAufServer, .none:
                Text(app: "profiles.pinResetWaiting \(name)")
            }
        }
        .font(TypeLevel.label.font)
        .foregroundStyle(ColorRole.progress.color)
        .lineLimit(1)
    }
}
