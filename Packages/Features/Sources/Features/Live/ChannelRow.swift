import Core
import DesignSystem
import Foundation
import SwiftUI

/// A row of the channel list: logo, name, current show.
///
/// **All measures are stated as values and calculated against each other** — see
/// ``textWidth`` and ``height``. The reason is a quirk of SwiftUI that otherwise
/// silently breaks this area: content that is too wide is centered and overflows to
/// **both** sides, without a warning. For a row bounded on the left by the
/// channel name and on the right by the program line, that does not look like
/// a space error but like a cut-off name.
struct ChannelRow: View {

    let channel: Channel
    /// What is currently on, if known. `nil` means: **no second line.**
    ///
    /// Of 5389 channels, 610 find a program entry. For the rest the
    /// line is left out — an empty placeholder or a spinner that never finishes
    /// would be visible on nine of ten rows and make the list restless.
    let programs: Programme?
    let now: Date
    let isFocused: Bool

    // MARK: - Dimensions

    /// The size of the channel logo, taken from the design template.
    static let logoSize = CGSize(width: 78, height: 50)

    /// Distance to the edge of the row.
    static let inset: CGFloat = 20

    /// Distance between logo, text and badge.
    static let gap: CGFloat = 20

    /// The space for the "LIVE" badge at the right edge.
    ///
    /// **Always kept free, even when it is not shown.** It appears only on the
    /// row in focus; if it took space only then, the channel name would shift by 116 points on every
    /// focus change — a movement that looks like an error.
    static let badgeWidth: CGFloat = 96

    /// What remains for name and show: 366 points.
    ///
    /// Calculated and not estimated, so that the rest of the row adds up verifiably —
    /// see the check in `LiveModelTests`.
    static var textWidth: CGFloat {
        LiveView.listWidth - 2 * inset - logoSize.width - gap - badgeWidth - gap
    }

    /// Line height of the name.
    ///
    /// **Derived and not copied, and that was once different.** When the styles
    /// for the 55-inch TV were raised by two points, the measure for the old size
    /// still stood here. No test case reported it, because the number had nothing to do with
    /// ``Tokens/Typography`` — it was a copy, and a copy
    /// does not notice when the original changes. It would have shown up as a
    /// clipped descender, that is, as bad type and not as an error.
    static let nameLineHeight = TypeLevel.lineHeight(zu: TypeLevel.footer.points)

    /// Line height of the program line.
    static let subLineHeight = TypeLevel.lineHeight(zu: TypeLevel.lowercased.points)

    /// The space for name and program line together — **always both**.
    ///
    /// Set as a fixed height and not merely calculated. Otherwise the name sits
    /// in the middle of the row while the show is missing, and jumps up by 15 points
    /// as soon as it has loaded. The row itself would stay the same height,
    /// so the list would stand still — but the name in focus would hop, and at
    /// exactly the moment the viewer reads it.
    static var textHeight: CGFloat { nameLineHeight + subLineHeight }

    static let insetVertical: CGFloat = 12

    /// The height is **fixed**, even with single-line content.
    ///
    /// The program loads later — the second line appears while the
    /// list is already standing. If the row grew in the process, everything
    /// below it would shift, and right out from under the user's focus.
    static var height: CGFloat {
        2 * insetVertical + max(logoSize.height, textHeight)
    }

    /// Spacing between two rows, from the design template.
    static let spacing: CGFloat = 6

    var body: some View {
        HStack(spacing: Self.gap) {
            logo

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: channel.cleanName)
                    .font(TypeLevel.footer.font)
                    .fontWeight(.semibold)
                    .foregroundStyle(isFocused ? ColorRole.reason.color : ColorRole.text.color)
                    .lineLimit(1)

                if let line = programmeLine {
                    Text(verbatim: line)
                        .font(TypeLevel.lowercased.font)
                        .foregroundStyle(
                            isFocused
                                ? ColorRole.textOnLight.color.opacity(0.7)
                                : ColorRole.textMatt.color
                        )
                        .lineLimit(1)
                }
            }
            .frame(width: Self.textWidth, height: Self.textHeight, alignment: .topLeading)

            badge
        }
        .padding(.horizontal, Self.inset)
        .padding(.vertical, Self.insetVertical)
        .frame(width: LiveView.listWidth, height: Self.height, alignment: .leading)
        .background(
            isFocused ? ColorRole.text.color : ColorRole.surface.color.opacity(0.55),
            in: RoundedRectangle(cornerRadius: MetricsBoard.tv.cardRadius, style: .continuous)
        )
    }

    /// Title and remaining time in one line.
    ///
    /// Composed and not two views: the title may be truncated,
    /// the remaining time may not — in a shared line with `lineLimit(1)` the
    /// end of the title drops off and the number stays, which is the right order.
    /// If nothing is running, **no** line is created.
    ///
    /// Not sealed off, so that the check can prove exactly that: `nil` means
    /// in the body above that the second view is not created at all.
    var programmeLine: String? {
        guard let programs else { return nil }
        guard let minutes = LiveModel.remainingMinutes(of: programs, at: now) else {
            return programs.title
        }
        return programs.title + " · " + Self.remainingText(minutes)
    }

    /// The remaining time as text.
    ///
    /// From the language file, because "24 min left" is worded differently in three languages. As a
    /// string and not as `Text`, because it sits with the title in **one**
    /// truncatable line — two views side by side could not
    /// decide which of the two gives way.
    static func remainingText(_ minutes: Int) -> String {
        String(
            format: NSLocalizedString(
                "live.remaining %lld", bundle: AppLanguageSetting.bundles(zu: "live.remaining %lld"),
                comment: ""),
            minutes
        )
    }

    /// The logo, or the initials.
    ///
    /// A substitute made of letters and not an empty field: not every provider delivers
    /// an image for every channel, and a list with holes reads worse than
    /// one with abbreviations.
    private var logo: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isFocused ? ColorRole.reason.color.opacity(0.14) : ColorRole.surfaceHigh.color)

            if channel.logoURL != nil {
                // **It matters especially here.** A channel icon comes from the provider in
                // the size it chose — among 5389 channels there are
                // full-size images. Nothing can be requested, the address is foreign;
                // decoding at reduced size happens anyway.
                RemoteImage(
                    url: channel.logoURL,
                    contentMode: .fit,
                    displaySize: Self.logoSize,
                    headroom: 1
                )
                .padding(4)
            } else {
                Text(verbatim: Self.initials(of: channel))
                    // festeschrift: 26 instead of 20 — this is the substitute for a missing channel icon
                    // and thus the only thing by which the channel in the list can be
                    // recognized. 20 points were too small for that.
                    .font(.system(size: 26, weight: .heavy))
                    .foregroundStyle(
                        isFocused ? ColorRole.surfaceHigh.color : ColorRole.textMatt.color
                    )
            }
        }
        .frame(width: Self.logoSize.width, height: Self.logoSize.height)
    }

    /// The initials of the first two words.
    ///
    /// **From ``Channel/searchKey`` and not from the displayed name**, although the
    /// key otherwise has no business on the screen. The reason is the
    /// provider prefix: it is still part of the displayed name — `cleanName` folds
    /// only the decorations —, and `DE| WELLE ENTERTAINMENT ᴴᴰ` would become `DW`. In the
    /// recorded catalog 4521 of 5389 names carry such a prefix,
    /// "DE:" alone 1313 times; in a list without logos almost every field would then show
    /// the same letter, and the abbreviation would no longer distinguish anything. The
    /// key cuts off the prefix, so `WE`.
    ///
    /// Two letters from a mangled value are acceptable; a
    /// re-implemented cutting off of the prefix would not be, because it would drift away from
    /// ``ChannelName``.
    static func initials(of channel: Channel) -> String {
        let words = channel.searchKey.split(separator: " ")
        let letters = words.prefix(2).compactMap(\.first)

        // The key can come out empty if the name consists only of the prefix.
        // An empty field would look like a loading error, so then the
        // displayed name steps in.
        guard !letters.isEmpty else {
            return String(channel.cleanName.prefix(2)).uppercased()
        }
        return String(letters).uppercased()
    }

    /// The "LIVE" badge — only on the row in focus.
    ///
    /// On every row it would stand eight times in a column and say nothing; on the row
    /// in focus it says what a press on the center triggers.
    @ViewBuilder
    private var badge: some View {
        if isFocused {
            HStack(spacing: 8) {
                Circle()
                    .fill(ColorRole.live.color)
                    .frame(width: 10, height: 10)
                Text(app: "player.live")
                    .font(TypeLevel.lowercased.font)
                    .fontWeight(.semibold)
                    .foregroundStyle(ColorRole.live.color)
            }
            .frame(width: Self.badgeWidth, alignment: .trailing)
        } else {
            // The same space, just empty. Nothing visible, everything for the layout —
            // the reasoning is documented at ``badgeWidth``.
            Color.clear
                .frame(width: Self.badgeWidth, height: 1)
        }
    }
}
