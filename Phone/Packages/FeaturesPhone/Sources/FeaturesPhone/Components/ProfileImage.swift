import DesignSystemPhone
import ProfileKit
import SwiftUI

/// The profile picture at the top right — and at the same time the way to switch accounts.
///
/// It sits in the same place on **every** tab screen. From a presented screen the way
/// therefore first leads back to where it sits: An account switch in the middle of the
/// settings would be a switch underneath a screen that belongs to the old account.
///
/// **With a picture since AP49** — the crop around the face from ``ProfileCircle``. The
/// profile comes from the environment (``SwiftUI/EnvironmentValues/headerProfile``) and
/// not as a parameter: The header appears in eight screens, and each of them already
/// passes the name through as a string. A second value on the same path would be eight
/// more call sites for a piece of information that is the same everywhere.
struct ProfileImage: View {

    @Environment(\.headerProfile) private var profile

    let name: String
    var action: () -> Void

    private var initial: String {
        String(name.prefix(1)).uppercased()
    }

    /// The profile's color — **`nil` without a profile**: Then the circle stays as it was
    /// before AP49, on the muted surface.
    private var profileColor: Color? {
        profile.flatMap { ProfileColor.tag($0.color.rawValue) }
    }

    var body: some View {
        Button(action: action) {
            ProfileCircle(
                letter: initial, avatar: profile?.avatar, edge: 32,
                font: TypeLevel.footer.font.weight(.semibold),
                letterColor: profileColor == nil ? ColorRole.text.color : ColorRole.reason.color,
                surface: profileColor ?? ColorRole.surfaceHigh.color
            )
            .overlay { Circle().strokeBorder(ColorRole.outline.color, lineWidth: 0.5) }
        }
        .target()
        .accessibilityLabel(Text(appKey: "account.switch"))
    }
}

extension EnvironmentValues {
    /// The profile behind the header's profile picture (AP49) — set once in the shell.
    @Entry var headerProfile: Profile? = nil
}
