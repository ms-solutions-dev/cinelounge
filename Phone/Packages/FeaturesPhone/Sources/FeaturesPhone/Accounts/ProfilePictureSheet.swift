import DesignSystemPhone
import ProfileKit
import SwiftUI

/// Choose the profile picture — **sixteen motifs and "No image", the preview above.**
///
/// **The phone side of AP49** (concept addendum N3): the same choice as in the TV's
/// `ProfileSheet`, only as a grid for the thumb — four columns on the phone, six on the iPad
/// (``MetricClass/profileImageColumns(_:)``). Both write the same field, the cloud reconciles
/// it like name and color.
///
/// **The preview shows both of what will result:** the cover image and the circle above it, exactly
/// as in the ``ProfileHeader``. Whoever chooses sees before saving what will stand in the person sheet and at the top
/// right.
///
/// **The tiles show the circle and not the whole motif.** The circle is what one
/// sees afterwards in four places; the whole motif is shown above in the preview as soon as
/// one taps.
///
/// **With "Reduce Motion" no transition** — the cover image then changes abruptly.
struct ProfilePictureSheet: View {

    @Environment(\.horizontalSizeClass) private var width
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var choice: ProfilePictureChoice
    let save: (ProfilePictureChoice) -> Void

    init(choice: ProfilePictureChoice, save: @escaping (ProfilePictureChoice) -> Void) {
        _choice = State(initialValue: choice)
        self.save = save
    }

    private static let previewEdge: CGFloat = 72

    var body: some View {
        SheetFrame(title: "profiles.avatar") {
            lookahead
                .padding(.horizontal, MetricsBoard.phone.margin)
                .padding(.bottom, MetricsBoard.phone.section)

            raster
                .padding(.horizontal, MetricsBoard.phone.margin)
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                save(choice)
            } label: {
                Text(app: "common.save")
            }
            .buttonStyle(.loud)
            .frame(maxWidth: MetricClass.buttonWidth(width))
            .padding(.horizontal, MetricsBoard.phone.margin)
            .padding(.vertical, MetricsBoard.phone.gutter)
            .background(ColorRole.surfaceHigh.color)
        }
    }

    private var lookahead: some View {
        ProfileTitleImage(
            avatar: choice.avatar, color: choice.color, height: MetricClass.titleImageHeight(width)
        )
        .clipShape(RoundedRectangle(cornerRadius: MetricsBoard.phone.cardRadius, style: .continuous))
        .overlay(alignment: .bottom) {
            ProfileCircle(
                letter: choice.initial, avatar: choice.avatar,
                edge: Self.previewEdge, font: TypeLevel.title.font,
                letterColor: ColorRole.reason.color, surface: colorSurface
            )
            .overlay { Circle().strokeBorder(ColorRole.surfaceHigh.color, lineWidth: 3) }
            .offset(y: Self.previewEdge / 2)
        }
        .padding(.bottom, Self.previewEdge / 2)
        .animation(reduceMotion ? nil : Motion.expand, value: choice.avatar)
        .accessibilityHidden(true)
    }

    private var raster: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: MetricsBoard.phone.gutter),
                count: MetricClass.profileImageColumns(width)),
            spacing: MetricsBoard.phone.gutter
        ) {
            tile(
                avatar: nil, info: "profiles.avatarNone", chosen: choice.hasNoPictureChosen
            ) { choice.withoutImage() }

            ForEach(AvatarMotif.all) { motif in
                tile(
                    avatar: motif.name, info: motif.info,
                    chosen: choice.avatar == motif.name
                ) { choice.select(motif) }
            }
        }
    }

    private var colorSurface: Color {
        ProfileColor.tag(choice.color.rawValue) ?? ColorRole.surfaceHigh.color
    }

    /// A tile — **the circle with a ring when it is chosen.**
    ///
    /// **The ring and not a checkmark.** A checkmark on a face covers exactly what
    /// the tile is recognized by; the ring encloses it. The choice is read aloud via
    /// ``AccessibilityTraits/isSelected`` and the name of the motif via ``ProfileKit/AvatarMotif/info``.
    private func tile(
        avatar: String?, info: String, chosen: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            GeometryReader { space in
                let edge = min(space.size.width, space.size.height)
                ProfileCircle(
                    letter: choice.initial, avatar: avatar,
                    edge: edge - 8, font: TypeLevel.section.font,
                    letterColor: ColorRole.reason.color, surface: colorSurface
                )
                .frame(width: space.size.width, height: space.size.height)
                .overlay {
                    Circle()
                        .strokeBorder(chosen ? ColorRole.brandLight.color : .clear, lineWidth: 3)
                        .frame(width: edge, height: edge)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(appKey: info))
        .accessibilityAddTraits(chosen ? [.isSelected] : [])
    }
}
