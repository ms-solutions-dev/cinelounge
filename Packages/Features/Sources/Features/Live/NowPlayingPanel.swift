import Core
import DesignSystem
import SwiftUI

/// The board on the right: the channel in focus, what is on it, and the way in.
///
/// **The preview, and what the one allowed connection really says about it.** Here
/// it said a preview was ruled out because the checked account
/// carries `max_connections 1`. That was too narrow: the limit forbids two
/// **simultaneously** open streams, not two in sequence. The preview gives up its
/// stream before playback starts — then only one is ever open.
///
/// What remains is a residue: whether the provider releases the connection immediately
/// is up to it. That is why the preview can be switched off and is **off by default**; the
/// reasoning in detail is documented at ``LivePreferences/previewsChannels``.
///
/// The occasion to reconsider this was an observation: one 4K channel could never be
/// played, others at any time. An occupied connection does not explain that — it
/// would hit all channels equally. The provider simply does not deliver this one;
/// when measured, it answers with a redirect to a black picture.
struct NowPlayingPanel: View {

    let channel: Channel?
    let guide: LiveModel.Guide
    let now: Date
    /// The running picture, when the dwell time has elapsed and the preview
    /// is switched on. Without it things stay at the logo.
    var preview: PlaybackTarget?
    let onPlay: () -> Void
    let onToggleFavorite: () -> Void

    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case play
        case favorite
    }

    // MARK: - Dimensions
    //
    // The board takes the width that remains next to the channel list. It therefore does not
    // stand there with a fixed width but with a **minimum width**
    // against which calculation is done — see the check in `LiveModelTests`.

    /// The image board for the logo. Wide format, because channel logos are wide — one
    /// framed upright would be either distorted or half cut off.
    static let tileSize = MetricsBoard.tv.episode

    /// Spacing between image board and the details next to it.
    static let tileGap: CGFloat = 32

    /// What the column with name, group and current show needs at least.
    ///
    /// 240 points at font size 48 are about eight characters per line — for "SOLA
    /// CINEMA" on two lines that is enough, below it the name starts to fall apart.
    static let headingMinimumWidth: CGFloat = 240

    /// What the board as a whole needs at least.
    ///
    /// This number is calculated against, not a fixed width: the board takes
    /// the space that remains next to the channel list. Below it the
    /// image board would stand wider than its space, and SwiftUI centers content that is too wide —
    /// it would run over the channel list on the left and out of the picture on the right.
    static var minimumWidth: CGFloat { tileSize.width + tileGap + headingMinimumWidth }

    // The row heights of the header column are stated as values, because the height of the whole board
    // depends on them — see ``tileRowHeight``.
    //
    // **Three copied numbers stood here, and two of them were wrong.** The
    // explanations still spoke of font sizes 25 and 23; since the 55-inch
    // adjustment the styles are at 27 and 25. The header column was thus dimensioned six points too
    // tightly — not enough to be noticed, enough for clipped
    // descenders. Now every row height comes from the same calculation as the font.

    /// One line of the channel name. Two are allowed.
    static let headingNameLineHeight = TypeLevel.lineHeight(
        zu: TypeLevel.section.points)

    /// One line for group and show title.
    static let headingInfoLineHeight = TypeLevel.lineHeight(
        zu: TypeLevel.footer.points)

    /// The line with the remaining time.
    static let headingRemainingLineHeight = TypeLevel.lineHeight(
        zu: TypeLevel.lowercased.points)

    static let headingSpacing: CGFloat = 12

    /// What the header column needs in the worst case.
    ///
    /// Worst case means: two-line channel name, group, two-line
    /// show title, remaining time. That is not the exceptional case — in the recorded
    /// catalog 4521 of 5389 names carry a provider prefix and thereby become so
    /// long that at font size 48 they go onto two lines.
    ///
    /// The number is an upper bound only because every line below it carries a
    /// `lineLimit`. If one of them is dropped, this calculation is worthless.
    static var headingHeight: CGFloat {
        2 * headingNameLineHeight + 2 * headingInfoLineHeight + headingRemainingLineHeight
            + 3 * headingSpacing
    }

    /// The height of the top row: image board **or** header column, whichever is taller.
    ///
    /// **The header column is taller, and an error hung on that.** Previously the
    /// calculation used ``tileSize``; with a two-line channel name and a running
    /// show, however, the row becomes 282 instead of 236 points tall, and the board pushed
    /// itself down by 46 points. Because it stands in the same `VStack` as title and
    /// group tabs, not only something at the bottom gets cut off in the process: SwiftUI centers
    /// a `VStack` that is too tall, so the title moves beyond the upper
    /// edge of the screen. Both without a warning.
    static var tileRowHeight: CGFloat { max(tileSize.height, headingHeight) }

    /// What the buttons take up in height, with the spacing above.
    static let actionsHeight: CGFloat = 108

    /// What the bandwidth hint takes up — two lines and the spacing above.
    static let hintHeight: CGFloat = 104

    /// The spacing above the program list, from ``guideList``.
    static let guideTop: CGFloat = 30

    /// Height of a program row.
    static let guideRowHeight: CGFloat = 54

    static let guideRowSpacing: CGFloat = 4

    /// How many program rows still have room under all this: four.
    ///
    /// **Calculated, not chosen.** The fetch delivers 24 entries; writing them all
    /// out would yield a list that runs off the bottom of the screen. And because the
    /// program rows do not accept the focus — they are text and not buttons —,
    /// you cannot scroll to them. A list that cannot be reached
    /// must not be longer than the screen.
    ///
    /// The spacing above the list and the one between the rows are part of the
    /// calculation. Without them 46 points would be missing with five rows, and exactly the one row
    /// too many ran out at the bottom.
    static var maximumGuideRows: Int {
        let used =
            LiveView.contentTop + tileRowHeight + actionsHeight + hintHeight + guideTop
            + TVMetrics.topMargin
        let room = LiveView.screenHeight - used
        // n rows take up n heights and n-1 spacings.
        return max(1, Int((room + guideRowSpacing) / (guideRowHeight + guideRowSpacing)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let channel {
                content(channel)
            } else {
                // No channel in focus — for example while loading. An empty box
                // would look like an error, a hint would not.
                Text(app: "live.panelHint")
                    .font(TypeLevel.footer.font)
                    .foregroundStyle(ColorRole.textQuiet.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: Self.minimumWidth, maxWidth: .infinity, alignment: .topLeading)
        // **A focus section of its own, otherwise you cannot get here at all.**
        //
        // The channel list next to it is one, and that was not enough: a section keeps
        // the focus within itself as long as the neighbor is not one — the press to the right
        // then kept searching within the list and found nothing. The buttons stood
        // visibly on screen and could not be reached, so no channel could be added
        // to the favorites.
        //
        // Why the list needs its section is justified separately — it scrolls,
        // and the geometrically nearest neighbor then lies outside. Two sections
        // side by side solve both: within one the focus stays, in between it jumps.
        .focusSection()
    }

    // MARK: - Content

    private func content(_ channel: Channel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: Self.tileGap) {
                tile(channel)
                heading(channel)
            }
            // **Fixed height, and that is a correction** (viewer finding
            // 2026-08-08: "the area is always empty"). The header column ends with
            // a `Spacer`, so that its rows stand at the top — without a limit that
            // makes the whole row greedy: it took the full remaining height of the
            // screen, and between the remaining time and the buttons gaped a
            // band of nothing. ``tileRowHeight`` is exactly the height that
            // ``maximumGuideRows`` calculates with anyway — now calculation and
            // picture agree.
            .frame(height: Self.tileRowHeight, alignment: .top)

            actions(channel)
            bandwidthHint
            guideList
        }
    }

    private func tile(_ channel: Channel) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: MetricsBoard.tv.fieldRadius, style: .continuous)
                .fill(ColorRole.surface.color)

            // The running picture takes the place of the logo as soon as it is there —
            // the same movement as with the trailer in the information column. A
            // second place next to it would make the board jump on every focus change.
            if let preview {
                ChannelPreview(target: preview, size: Self.tileSize)
            } else if channel.logoURL != nil {
                RemoteImage(
                    url: channel.logoURL,
                    contentMode: .fit,
                    displaySize: Self.tileSize,
                    headroom: 1
                )
                .padding(30)
            } else {
                Text(verbatim: ChannelRow.initials(of: channel))
                    .font(TypeLevel.title.font)
                    .foregroundStyle(ColorRole.textQuiet.color)
            }
        }
        .frame(width: Self.tileSize.width, height: Self.tileSize.height)
    }

    private func heading(_ channel: Channel) -> some View {
        // Every line here carries a `lineLimit`, and that is no subtlety of
        // presentation: ``headingHeight`` calculates with these limits, and the height of the
        // whole board depends on it.
        VStack(alignment: .leading, spacing: Self.headingSpacing) {
            Text(verbatim: channel.cleanName)
                .font(TypeLevel.section.font)
                .foregroundStyle(ColorRole.text.color)
                .lineLimit(2)

            if let group = channel.group, !group.isEmpty {
                Text(verbatim: ChannelName.display(group))
                    .font(TypeLevel.footer.font)
                    .foregroundStyle(ColorRole.textMatt.color)
                    .lineLimit(1)
            }

            if let running = runningProgramme {
                Text(verbatim: running.title)
                    .font(TypeLevel.footer.font)
                    .foregroundStyle(ColorRole.text.color)
                    .lineLimit(2)

                if let minutes = LiveModel.remainingMinutes(of: running, at: now) {
                    Text(app: "live.remaining \(minutes)")
                        .font(TypeLevel.lowercased.font)
                        .foregroundStyle(ColorRole.live.color)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(minWidth: Self.headingMinimumWidth, maxWidth: .infinity, alignment: .leading)
    }

    private var runningProgramme: Programme? {
        guard case .listing(let listing) = guide else { return nil }
        return listing.first { $0.isRunning(at: now) }
    }

    // MARK: - Buttons

    private func actions(_ channel: Channel) -> some View {
        HStack(spacing: 20) {
            Button(action: onPlay) {
                Label(app: "common.play", systemImage: "play.fill")
                    .font(TypeLevel.footer.font)
                    .fontWeight(.semibold)
                    .foregroundStyle(
                        focus == .play ? ColorRole.reason.color : ColorRole.text.color
                    )
                    .padding(.horizontal, 34)
                    .padding(.vertical, 18)
                    .background(
                        focus == .play ? ColorRole.text.color : ColorRole.tag.color,
                        in: Capsule()
                    )
            }
            .bareFocusableButton()
            .focused($focus, equals: .play)
            .focusHighlight(focus == .play, scale: Tokens.Focus.buttonScale)

            Button(action: onToggleFavorite) {
                Label(
                    app: channel.isFavorite ? "common.unfavorite" : "live.favoriteAdd",
                    // **The same symbol as in the player bar** (AP25): there
                    // has always been a heart (``TransportBar``), here a
                    // star stood — for the same thing, two handles apart.
                    systemImage: Glyph.favorite.pair.forItem(channel.isFavorite)
                )
                .font(TypeLevel.footer.font)
                .foregroundStyle(
                    focus == .favorite ? ColorRole.reason.color : ColorRole.textMatt.color
                )
                .padding(.horizontal, 30)
                .padding(.vertical, 18)
                .background(
                    focus == .favorite ? ColorRole.text.color : ColorRole.surfaceHigh.color,
                    in: Capsule()
                )
            }
            .bareFocusableButton()
            .focused($focus, equals: .favorite)
            .focusHighlight(focus == .favorite, scale: Tokens.Focus.buttonScale)
        }
        .padding(.top, 30)
        // A section of its own: the focus should jump over as a whole from the channel list
        // and not oscillate row by row between list and button.
        .focusSection()
    }

    /// The bandwidth hint.
    ///
    /// **Stands there permanently and not only in the error case.** A channel runs at
    /// a measured 17 Mbit/s, and unlike with Jellyfin nobody can
    /// transcode it down — through the tunnel at a measured 0.3 Mbit/s no picture arrives.
    /// A black picture that gives up after twenty seconds is not information;
    /// this sentence beforehand is.
    private var bandwidthHint: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 22))
                .foregroundStyle(ColorRole.textQuiet.color)
            Text(app: "live.bandwidthHint")
                .font(TypeLevel.lowercased.font)
                .foregroundStyle(ColorRole.textQuiet.color)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 26)
    }

    // MARK: - Programme

    /// The upcoming shows, the running one highlighted.
    ///
    /// In the case of ``LiveModel/Guide/pending`` **nothing** stands here: as long as nothing
    /// was asked, there is nothing to report. A spinner at this place would stay
    /// forever on nine of ten channels — 610 of 5389 find an
    /// entry —, and a spinner that never finishes reads as an error.
    @ViewBuilder
    private var guideList: some View {
        switch guide {
        case .pending:
            EmptyView()

        case .none:
            Text(app: "live.noGuide")
                .font(TypeLevel.lowercased.font)
                .foregroundStyle(ColorRole.textQuiet.color)
                .padding(.top, Self.guideTop)

        case .listing(let listing):
            VStack(alignment: .leading, spacing: Self.guideRowSpacing) {
                ForEach(upcoming(listing)) { programs in
                    guideRow(programs)
                }
            }
            .padding(.top, Self.guideTop)
        }
    }

    /// What comes from now on, capped to the rows that fit on screen.
    ///
    /// Past shows drop out: the fetch also delivers what ran this morning,
    /// and these rows would take the space of the next hours.
    private func upcoming(_ listing: [Programme]) -> [Programme] {
        Array(listing.filter { $0.end > now }.prefix(Self.maximumGuideRows))
    }

    private func guideRow(_ programs: Programme) -> some View {
        let isRunning = programs.isRunning(at: now)

        return HStack(alignment: .top, spacing: 22) {
            // Digits of equal width, so that the titles next to them form a column.
            // With proportional width every row dances by a few points.
            Text(programs.start, format: .dateTime.hour().minute())
                .monospacedDigit()
                .foregroundStyle(isRunning ? ColorRole.live.color : ColorRole.textMatt.color)
                .frame(width: 120, alignment: .leading)

            Text(verbatim: programs.title)
                .foregroundStyle(isRunning ? ColorRole.text.color : ColorRole.textMatt.color)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .font(TypeLevel.footer.font)
        .fontWeight(isRunning ? .semibold : .regular)
        .padding(.horizontal, 18)
        .frame(height: Self.guideRowHeight, alignment: .center)
        .background(
            isRunning ? ColorRole.surface.color : .clear,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }
}
