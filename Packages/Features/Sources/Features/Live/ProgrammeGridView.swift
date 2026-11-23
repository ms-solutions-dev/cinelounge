import Core
import DesignSystem
import Flows
import SwiftUI

/// The program grid: channels on the left, time on the right.
///
/// **The view the Live block exists for** (`design/konzept-p8.md`,
/// section 3). What it shows is calculated by ``ProgramGrid`` — here is only
/// how it looks and how it is operated.
///
/// ## Why it pages and does not scroll
///
/// A freely scrolling grid over three days is a test of patience with a remote without a
/// wheel, and the channel column would have to stay in place while
/// the rest moves — two scroll areas that you keep level by hand.
/// The window here is **two hours wide and jumps by one**: the right
/// edge of the old window then stands in the middle, so nobody loses
/// orientation. The channel column stands because it never moves.
///
/// ## The hole is the normal case
///
/// 89 percent of the test provider's channels carry no program. Their row
/// shows the channel name over the full width — selectable, playable, and
/// precisely **not** drawn like an error.
struct ProgrammeGridView: View {

    var model: GuideGridModel
    /// The current time — from outside, so that the now line moves with the pace of the
    /// view and not with a clock of its own.
    let now: Date
    /// What a press triggers — with the box, because a past entry
    /// means something different from a running one (catch-up instead of channel).
    let onPlay: (Channel, ProgramGrid.Cell) -> Void
    let onLeaveToList: () -> Void

    @FocusState private var focus: String?

    // MARK: - Dimensions

    /// Width of the channel column. Two lines of channel name at the usual
    /// length — measured against "Pusula SPORTS MAX 1 FHD".
    private static let channelColumn: CGFloat = 340
    /// Height of a row. The same order as ``ChannelRow``, so that the
    /// switch between list and grid does not feel like a different area.
    private static let lineHeight: CGFloat = 92
    private static let rowGap: CGFloat = 8
    private static let cellSpacing: CGFloat = 4
    /// The narrowest cell that can still be hit.
    ///
    /// A show of five minutes would be 40 points wide with a two-hour window
    /// — a line that accepts the focus but shows nothing.
    /// Below that nothing is drawn; it is added to the neighboring cell;
    /// that comes from ``ProgramGrid/smallestGap`` for gaps and from here for
    /// everything else.
    private static let narrowest: CGFloat = 56

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            // **No program is information, not an empty screen.** A
            // grid without a single show looks like an error; it is
            // however the normal case as long as no sync has run. The sentence says
            // what to do.
            if model.isReady, model.rows.allSatisfy({ !$0.hasProgram }) {
                Text(app: "live.rasterEmpty")
                    .font(TypeLevel.text.font)
                    .foregroundStyle(ColorRole.textMatt.color)
                    .padding(.top, 40)
                    .padding(.leading, Self.channelColumn)
            }

            GeometryReader { space in
                let width = max(space.size.width - Self.channelColumn, 200)
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: Self.rowGap) {
                        ForEach(model.rows) { row in
                            self.row(row, width: width)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .overlay(alignment: .topLeading) {
                    nowLine(width: width, height: space.size.height)
                }
            }
        }
    }

    // MARK: - Header: time axis and paging

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                pageButton(.back, id: "raster-zurueck")
                pageButton(.forward, id: "raster-vor")

                // **"Now" only if there is something to do.** A button that
                // does nothing is a stop in the focus path without a destination.
                if !model.showsNow(now) {
                    Button {
                        model.backToNow(now: now)
                    } label: {
                        Text(app: "live.rasterNow")
                            .font(TypeLevel.footer.font)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 8)
                    }
                    .bareFocusableButton()
                    .focused($focus, equals: "raster-jetzt")
                }

                Text(span)
                    .font(TypeLevel.footer.font)
                    .foregroundStyle(ColorRole.textMatt.color)
                    .monospacedDigit()
            }
            .padding(.leading, Self.channelColumn)

            GeometryReader { space in
                let width = max(space.size.width - Self.channelColumn, 200)
                timeline(width: width)
                    .padding(.leading, Self.channelColumn)
            }
            .frame(height: 26)
        }
        .padding(.bottom, 10)
    }

    private func pageButton(
        _ direction: GuideGridModel.Direction, id: String
    ) -> some View {
        Button {
            model.page(direction, now: now)
        } label: {
            // The symbol stands here and not as a parameter: the check of the
            // language keys otherwise reads a dotted text at the call site
            // as a missing translation — it is right to ask.
            Image(systemName: direction == .back ? "chevron.left" : "chevron.right")
                .font(.system(size: 22, weight: .semibold))
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
        }
        .bareFocusableButton()
        .focused($focus, equals: id)
        // **Here the symbol alone carries it** — `chevron.left` is a file name and
        // no information. The only button in the grid that said nothing at all.
        .info(appKey: direction == .back ? "raster.back" : "raster.forward")
    }

    /// "20:00 – 22:00" — the span of the window, not the time of day.
    private var span: String {
        let form = Date.FormatStyle(date: .omitted, time: .shortened)
        return "\(model.windowStart.formatted(form)) – \(model.windowEnd.formatted(form))"
    }

    /// The half-hourly marks above the grid.
    private func timeline(width: CGFloat) -> some View {
        let steps = Int(GuideGridModel.windowWidth / 1800)
        return ZStack(alignment: .topLeading) {
            ForEach(0..<steps, id: \.self) { index in
                let time = model.windowStart.addingTimeInterval(Double(index) * 1800)
                let x = width * CGFloat(index) / CGFloat(steps)
                Text(time.formatted(Date.FormatStyle(date: .omitted, time: .shortened)))
                    .font(TypeLevel.footer.font)
                    .monospacedDigit()
                    // The full hour carries, the half hour only helps.
                    .foregroundStyle(
                        index.isMultiple(of: 2) ? ColorRole.text.color : ColorRole.textMatt.color
                    )
                    .offset(x: x + 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// The standing mark in the accent color — only if "now" lies in the window.
    @ViewBuilder
    private func nowLine(width: CGFloat, height: CGFloat) -> some View {
        if model.showsNow(now) {
            let portion =
                now.timeIntervalSince(model.windowStart) / GuideGridModel.windowWidth
            Rectangle()
                .fill(ColorRole.live.color)
                .frame(width: 3, height: height)
                .offset(x: Self.channelColumn + width * CGFloat(portion))
                .allowsHitTesting(false)
        }
    }

    // MARK: - One row

    private func row(_ row: ProgramGrid.Row, width: CGFloat) -> some View {
        HStack(spacing: Self.cellSpacing) {
            channelCell(row.channels)

            // **One focus section per row** (concept, section 3):
            // vertically the focus should switch the channel, not get stuck within
            // a three-hour feature film.
            HStack(spacing: Self.cellSpacing) {
                ForEach(visible(row.cells, width: width), id: \.cell.id) { pair in
                    cellButton(pair.cell, width: pair.width, channels: row.channels)
                }
            }
            .focusSection()
        }
        .frame(height: Self.lineHeight)
    }

    /// Calculates the widths and discards what would be too narrow to hit.
    ///
    /// The dropped width goes to the neighboring cell — otherwise a gap would gape in the
    /// grid that does not exist in the show.
    private func visible(
        _ cells: [ProgramGrid.Cell], width: CGFloat
    ) -> [(cell: ProgramGrid.Cell, width: CGFloat)] {
        let total = GuideGridModel.windowWidth
        var result: [(cell: ProgramGrid.Cell, width: CGFloat)] = []
        var carry: CGFloat = 0
        for cell in cells {
            let raw = width * CGFloat(cell.visibleDuration / total) + carry
            if raw < Self.narrowest, !result.isEmpty {
                carry = raw
                continue
            }
            carry = 0
            result.append((cell, raw))
        }
        // What remains at the end goes to the last cell.
        if carry > 0, !result.isEmpty {
            result[result.count - 1].width += carry
        }
        return result
    }

    private func channelCell(_ channels: Channel) -> some View {
        HStack(spacing: 12) {
            RemoteImage(
                url: channels.logoURL,
                contentMode: .fit,
                displaySize: CGSize(width: 56, height: 40),
                headroom: 1
            )
            .frame(width: 56, height: 40)
            Text(channels.cleanName)
                .font(TypeLevel.text.font)
                .foregroundStyle(ColorRole.text.color)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(width: Self.channelColumn, height: Self.lineHeight, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(ColorRole.surface.color.opacity(0.45))
        )
    }

    private func cellButton(
        _ cell: ProgramGrid.Cell, width: CGFloat, channels: Channel
    ) -> some View {
        let isFocused = focus == "raster-\(cell.id)"
        let catchUp = Catchup.isInArchive(channels, start: cell.start, now: now)
        return Button {
            onPlay(channels, cell)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(cell.title)
                    .font(TypeLevel.text.font)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !cell.isGap, width >= 140 {
                    Text(
                        cell.start.formatted(
                            Date.FormatStyle(date: .omitted, time: .shortened))
                    )
                    .font(TypeLevel.footer.font)
                    .monospacedDigit()
                    .opacity(0.75)
                }
                Spacer(minLength: 0)
                // **Color AND symbol** (concept, section 4): a note
                // carried by color alone is missing for every tenth person.
                if catchUp, width >= 140 {
                    Label {
                        Text(app: "live.rasterRecording")
                    } icon: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .font(TypeLevel.footer.font)
                    .opacity(0.8)
                }
            }
            .foregroundStyle(isFocused ? ColorRole.reason.color : ColorRole.text.color)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(width: max(width - Self.cellSpacing, 40), alignment: .topLeading)
            .frame(height: Self.lineHeight - 8, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        isFocused
                            ? ColorRole.text.color
                                // **The gap looks different from a show, but
                                // not like an error**: muted background, no frame,
                                // no warning color. For 89 percent of the channels it is the
                                // normal case.
                            : (cell.isGap
                                ? ColorRole.surface.color.opacity(0.28)
                                : ColorRole.surfaceHigh.color)
                    )
            )
            // The running entry carries the accent color at the left edge — that is
            // the second piece of information next to the now line, and it stands even
            // when the line happens to lie behind a cell.
            .overlay(alignment: .leading) {
                if cell.state == .running {
                    Rectangle()
                        .fill(ColorRole.live.color)
                        .frame(width: 4)
                        .clipShape(
                            RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
        .bareFocusableButton()
        .focused($focus, equals: "raster-\(cell.id)")
        .focusHighlight(isFocused)
        // The past stays legible but recedes — it is not what
        // anyone is looking for in the grid.
        // **The past with catch-up stays bright** (concept, section 4:
        // "selectable instead of grayed out"). Grayed out would mean in the grid: does
        // not work — and for these 51 channels it would work just fine.
        .opacity(cell.state == .past && !isFocused && !catchUp ? 0.55 : 1)
    }
}
