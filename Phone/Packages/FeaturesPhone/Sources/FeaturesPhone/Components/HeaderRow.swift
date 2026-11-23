import DesignSystemPhone
import SwiftUI

/// The row above the content: the app name or a screen title on the left, on the right the
/// playback target and the profile picture.
///
/// **The playback target belongs here and not on a title.** It applies to the app and not to
/// a film — whoever casts to the TV casts everything that follows. In a bar below the header
/// area it stood next to a play button and looked like its accessory.
struct HeaderRow: View {

    var title: String?
    let account: String
    var onAccountTap: () -> Void
    var onTargetTap: (() -> Void)?

    /// Which target the button shows.
    ///
    /// **The button says where it goes, and not that it exists.** Until 2026-09-12
    /// ``Styling/Glyph/target`` always stood here — the same image whether something is
    /// playing on the TV or not. A target that one can choose and never sees again is not
    /// information but a guess.
    var target: PlaybackDestination = .phone
    var onFavoritesTap: (() -> Void)?

    /// **The sync button stood here, and the place now belongs to the downloads.**
    ///
    /// It came on 2026-09-07 as a product request (on tvOS there is a button that resynchronizes all
    /// content) and goes on 2026-09-08 at the same request: pulling down should additionally do
    /// exactly what the sync does. That would then cover everything.
    ///
    /// **Nothing was lost** — the capability moved to the gesture, it was not deleted:
    /// ``StartModel/refresh()``. What is gained is a place in a row in which there was no free
    /// one, and it is needed: five tabs are the limit, five are taken, and the downloads need
    /// their door. The header row is the right place for it because in this app it has long been
    /// the overflow of the tab bar — ``onFavoritesTap`` stands here by exactly the same rule.
    ///
    /// **And since 2026-09-08 it is there.** Reported with a screenshot: neither a button at the top
    /// here nor a button or download option within the content. Both held, and both had a
    /// different reason — one here, the other in ``ShellModel/buildDownloads()``.
    ///
    /// **It appears only where there is something to open.** Without configured sources there are
    /// no downloads, and a button to a screen that does not exist would be the dead end that has
    /// already been cleaned up twice in this project.
    var onDownloadsTap: (() -> Void)?

    /// The way to "Network and data usage" — **set only in the downloads.**
    ///
    /// It answers the question one has second most often on this one screen: after "what is here"
    /// comes "why is this not downloading". On Home or in the library nobody asks it — there the
    /// button would only be in the way.
    var onNetworkTap: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            if let title {
                LargeTitle(title: title)
            } else {
                BrandMark()
            }

            Spacer(minLength: MetricsBoard.phone.gutter)

            if let onFavoritesTap {
                HeaderButton(
                    icon: Glyph.favorite.pair.outlined, label: "tab.favorites",
                    action: onFavoritesTap)
            }

            // **The downloads stand here because the tab bar is full.** Five is the limit from which
            // captions break, and five are taken; in this app the header row is the overflow — the
            // favorites stand one row above by exactly the same rule.
            if let onDownloadsTap {
                HeaderButton(
                    icon: Glyph.downloads.name, label: "stock.title",
                    action: onDownloadsTap)
            }

            if let onNetworkTap {
                // **An antenna and not a checkmark.** In the downloads header
                // ``Styling/Glyph/done`` stood until AP3 — `checkmark.circle`, i.e. the sign for
                // "that's right". But it leads to "Network and data usage", and the button is pressed
                // because right now **nothing** is right.
                HeaderButton(
                    icon: Glyph.funk.name, label: "network.current",
                    action: onNetworkTap)
            }

            if let onTargetTap {
                HeaderButton(
                    icon: target.icon, label: "action.target",
                    action: onTargetTap)
            }

            ProfileImage(name: account, action: onAccountTap)
                .padding(.leading, Metrics.targetSpacing)
        }
        .padding(.horizontal, MetricsBoard.phone.margin)
    }
}

/// An icon button of the header row — **with real width instead of borrowed.**
///
/// **Why not ``SwiftUICore/View/textHitTarget()``** (finding of 2026-09-07, on screen): it lays the
/// hit area via negative padding **beyond the visible edge** — ten points on each side. With
/// two buttons eight points apart, two such areas overlap by twelve points, and SwiftUI gives
/// the surcharge to the one drawn later. A press on "Reload all" therefore opened the sheet
/// of the playback target, which sits to the right of it.
///
/// **Here the hit area takes up real space.** Forty-four points wide, the gap is inside it —
/// so no area can reach over that of its neighbor. The icon stays as large as it is:
/// enlarging a target never means enlarging its icon.
struct HeaderButton: View {

    let icon: String
    let label: String

    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .foregroundStyle(ColorRole.textMatt.color)
                .frame(width: Metrics.target, height: Metrics.target)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // **`appKey` and not `app`**: the key stands here in a property and is not known at compile
        // time.
        .accessibilityLabel(Text(appKey: label))
    }
}
