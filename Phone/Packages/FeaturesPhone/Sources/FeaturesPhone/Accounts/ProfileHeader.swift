import DesignSystemPhone
import ProfileKit
import SwiftUI

/// The header of the person sheet — **cover image, the circle above it, the name, "Change
/// profile picture".**
///
/// **The familiar pattern from profile pages** (concept addendum N2): the whole motif stands
/// as a banner at the top, the circle with the crop around the face overlaps its bottom edge.
/// Both are drawings of the same motif — a cover image is not a second field.
///
/// **Here and not in a profile page of its own**, because on the phone the person sheet *is*
/// the profile page: it starts from the profile picture, answers "who is watching" and is the
/// only place that is equally far away on every tab. A second page just for the
/// image would be one more path to something done rarely.
struct ProfileHeader: View {

    @Environment(\.horizontalSizeClass) private var width

    let profile: Profile
    /// Change the image — `nil` where the profile may not be managed (``KidsTargets``).
    let change: (() -> Void)?

    /// The edge of the large circle.
    ///
    /// **One number for both size classes.** The circle is a face and not an image that
    /// would have to grow with the surface; the banner above it grows, and that is enough.
    private static let edge: CGFloat = 88

    var body: some View {
        VStack(spacing: 0) {
            ProfileTitleImage(
                avatar: profile.avatar, color: profile.color,
                height: MetricClass.titleImageHeight(width)
            )
            .clipShape(RoundedRectangle(cornerRadius: MetricsBoard.phone.cardRadius, style: .continuous))
            .overlay(alignment: .bottom) {
                ProfileCircle(
                    letter: profile.initial, avatar: profile.avatar,
                    edge: Self.edge, font: TypeLevel.title.font,
                    letterColor: ColorRole.reason.color,
                    surface: ProfileColor.tag(profile.color.rawValue) ?? ColorRole.surfaceHigh.color
                )
                // **A ring in the sheet color** separates the circle from the banner — without it
                // a motif in the circle blurs with the same motif behind it.
                .overlay { Circle().strokeBorder(ColorRole.surfaceHigh.color, lineWidth: 3) }
                .offset(y: Self.edge / 2)
            }
            .padding(.bottom, Self.edge / 2)

            Text(verbatim: profile.name)
                .font(TypeLevel.header.font)
                .foregroundStyle(ColorRole.text.color)
                .padding(.top, MetricsBoard.phone.gutter)

            if let change {
                Button(action: change) {
                    Text(app: "profiles.avatarChange")
                }
                .buttonStyle(.quiet)
                .frame(maxWidth: MetricClass.buttonWidth(width))
                .padding(.top, MetricsBoard.phone.gutter)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, MetricsBoard.phone.margin)
        .padding(.bottom, MetricsBoard.phone.section)
        .accessibilityElement(children: .contain)
    }
}
