import DesignSystemPhone
import Flows
import ProfileKit
import SwiftUI

/// Sheet: **Who is watching?** — profiles and not credentials (G3, 2026-09-26).
///
/// **Finding B2 from the feature comparison:** until now this sheet listed the
/// Jellyfin accounts of the device, while on the TV the same question showed profiles. A profile
/// without a media server credential — a child with only a channel list, a grandparent with only portals — was
/// not selectable on the phone, and was created only on the TV. The guideline from
/// decision 25 (the same feel on every device) demands the same row: the circles
/// of the profiles, then "Create profile" (**always**, decision 3), "Add
/// credential" and "Manage profiles". The rules for this live shared in
/// ``Flows/ProfilePicker``; the accounts themselves live under `Settings → Media server`.
///
/// **The "Child mode" switch fell with G3** (finding C10). It stood here **and**
/// as "Parental controls on" in parental controls — two names and two places for one
/// device state. Now it is called "Device lock" on both devices and lives in ONE
/// place: in parental controls, behind its door.
///
/// **It starts from the profile picture**, which stands at the top right of every tab screen — the
/// only place that is the same everywhere. A switch is something you do in the middle of watching;
/// via Settings it would be three taps.
///
/// **For a child only the circles** (decision 20): no changing the picture, no PIN, no
/// creating, no settings. The sheet is then called "Switch profile" — the way out
/// of the child interface, as on the TV.
struct AccountSwitchSheet: View {

    @Environment(\.surface) private var surface

    /// The profiles, in the order of the book.
    let profile: [Profile]
    /// Wer gerade davorsitzt.
    let active: Profile.Identifier?
    /// Whose header is at the top — **`nil` means: no header.**
    let headerProfile: Profile?
    /// Open "forgot PIN" requests per profile — as a badge under the circle, as on the
    /// TV.
    var escapes = PinFallbacks.none
    /// The way into the image picker (AP49).
    let changeProfilePicture: () -> Void
    /// Whether the profile in the header carries its own PIN (AP52) — `nil` means: no header, so
    /// no row either.
    let isProfilePinSet: Bool?
    /// The way to the profile PIN — **through the parental-controls door**, see
    /// ``ShellModel/maintainProfilePin(forItem:)``.
    let profilePin: () -> Void
    /// Choose a profile — **through door and latch** (``ShellModel/switchProfile(_:)``).
    let select: (Profile) -> Void
    /// A handle beside the circles (``Flows/ProfilePicker/Action``).
    let handle: (ProfilePicker.Action) -> Void
    /// The way into Settings.
    let manage: () -> Void
    /// Whether management appears — **without a default**, so that no call site silently
    /// shows Settings to a child (``KidsTargets``).
    let isManageable: Bool

    /// The edge of a circle — **larger in the child interface** (``Styling/Surface``).
    private var edge: CGFloat { MetricsBoard.phone.person * surface.reference }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // **At the top is who is watching — with cover image and circle** (AP49).
            if let headerProfile {
                ProfileHeader(profile: headerProfile, change: isManageable ? changeProfilePicture : nil)
            }

            SettingsCard(header: isManageable ? "accounts.switcherTitle" : "sidebar.switchProfile") {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: MetricsBoard.phone.gutter) {
                        ForEach(profile, id: \.identifier.rawValue) { profile in
                            circle(profile)
                        }
                        ForEach(ProfilePicker.actions(switchOnly: !isManageable), id: \.self) { action in
                            grabberCircle(action)
                        }
                    }
                    .padding(.vertical, MetricsBoard.phone.gutter)
                    .padding(.horizontal, Metrics.cardInset)
                }
                .scrollIndicators(.hidden)
            }

            Footnote(message: "accounts.switcherHint")
                .padding(.bottom, MetricsBoard.phone.gutter)

            if isManageable { administration }
        }
        .padding(.top, MetricsBoard.phone.section)
        .padding(.bottom, MetricsBoard.phone.margin)
    }

    /// A profile as a circle with a name — **the active one with a checkmark, a child with a figure**: shape,
    /// not color (E47). The same row as on the TV.
    private func circle(_ profile: Profile) -> some View {
        let isActive = profile.identifier == active
        return Button {
            select(profile)
        } label: {
            VStack(spacing: 6) {
                ZStack(alignment: .bottomTrailing) {
                    ProfileCircle(
                        letter: profile.initial, avatar: profile.avatar, edge: edge,
                        font: TypeLevel.section.font,
                        letterColor: ColorRole.reason.color,
                        surface: ProfileColor.tag(profile.color.rawValue) ?? ColorRole.surfaceHigh.color)
                    if isActive {
                        Image(systemName: Glyph.done.pair.filled)
                            .font(TypeLevel.header.font)
                            .foregroundStyle(ColorRole.brandLight.color)
                            .background(ColorRole.surfaceHigh.color, in: Circle())
                            .accessibilityHidden(true)
                    }
                }
                Text(verbatim: profile.name)
                    .font(TypeLevel.footer.font)
                    .foregroundStyle(isActive ? ColorRole.text.color : ColorRole.textMatt.color)
                    .lineLimit(1)
                if profile.kind == .kind {
                    Label {
                        Text(app: "profiles.child")
                    } icon: {
                        Image(systemName: Glyph.kind.name)
                    }
                    .font(TypeLevel.label.font)
                    .foregroundStyle(ColorRole.textQuiet.color)
                }
                if let state = escapes.state(forItem: profile.identifier), state.pending {
                    Image(systemName: Glyph.info.name)
                        .font(TypeLevel.label.font)
                        .foregroundStyle(ColorRole.progress.color)
                        .accessibilityLabel(Text(app: "profiles.pinResetMark"))
                }
            }
            .frame(width: edge + MetricsBoard.phone.gutter * 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    /// A circle that is not a profile — **the same shape as the profiles**, so that the row
    /// stays one row; the symbol instead of a letter says that no person
    /// stands here. The "+" belongs to creating (decision 3), the credential carries the network symbol.
    private func grabberCircle(_ action: ProfilePicker.Action) -> some View {
        let (character, key): (String, String) =
            switch action {
            case .create: (Glyph.add.name, "profiles.add")
            case .manage: (Glyph.manageAccounts.name, "profiles.manage")
            }
        return Button {
            handle(action)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: character)
                    .font(TypeLevel.section.font)
                    .foregroundStyle(ColorRole.textMatt.color)
                    .frame(width: edge, height: edge)
                    .background(ColorRole.surface.color, in: Circle())
                Text(appKey: key)
                    .font(TypeLevel.footer.font)
                    .foregroundStyle(ColorRole.textMatt.color)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(width: edge + MetricsBoard.phone.gutter * 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Profile PIN and Settings — **only where managing is allowed.**
    private var administration: some View {
        SettingsCard {
            // **The profile PIN is in the person sheet** (AP52) — where the image and
            // name of the profile are as well: it belongs to the person in the header, not to the device.
            if let isProfilePinSet {
                DisclosureRow(
                    title: "profiles.pin", icon: Glyph.locked.name,
                    value: SettingsModel.text(
                        isProfilePinSet ? "common.on" : "common.off"),
                    isContained: true, action: profilePin)

                Separator(isIndented: true)
            }

            DisclosureRow(
                title: "settings.title", icon: Glyph.check.name,
                isContained: true, action: manage)
        }
    }
}
