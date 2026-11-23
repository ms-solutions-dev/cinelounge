import Core
import DesignSystemPhone
import Flows
import SwiftUI

/// The program grid **on the iPad** — channels on the left, two hours on the right
/// (decision 27, B10, 2026-09-26).
///
/// **Only in the wide size class.** On the iPhone (393 pt) a two-hour window
/// beside a channel column no longer carries titles; there the daily program per channel
/// remains (``ChannelDetailView``). The iPad has the width, and there is no reason to forgo the
/// TV's grid.
///
/// **Calculation and window are shared** (``Flows/GuideGridModel``,
/// ``Core/ProgramGrid``): the same window, the same step of one hour, the same
/// rule for a tap (``Flows/CatchUpSelection``) — a past broadcast in the archive
/// plays the recording, everything else the channel. Only the view is the phone's:
/// tapping instead of focus, and the time axis does not scroll, it pages.
struct ProgramGridView: View {

    let model: GuideGridModel
    let now: Date
    let tap: (Channel, ProgramGrid.Cell) -> Void

    private static let channelColumn: CGFloat = 180
    private static let lineHeight: CGFloat = 60
    private static let cellSpacing: CGFloat = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if model.isReady, model.rows.allSatisfy({ !$0.hasProgram }) {
                Text(appKey: "live.rasterEmpty")
                    .font(TypeLevel.footer.font)
                    .foregroundStyle(ColorRole.textMatt.color)
                    .padding(.horizontal, MetricsBoard.phone.margin)
                    .padding(.vertical, MetricsBoard.phone.gutter)
            }
            GeometryReader { space in
                let width = max(space.size.width - Self.channelColumn - MetricsBoard.phone.margin * 2, 200)
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: Self.cellSpacing) {
                        ForEach(model.rows) { row in
                            self.row(row, width: width)
                        }
                    }
                    .padding(.horizontal, MetricsBoard.phone.margin)
                }
                .overlay(alignment: .topLeading) { nowLine(width: width, height: space.size.height) }
            }
        }
    }

    // MARK: - Kopf

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: MetricsBoard.phone.gutter) {
                pageButton(.back)
                pageButton(.forward)
                if !model.showsNow(now) {
                    Button {
                        model.backToNow(now: now)
                    } label: {
                        Text(appKey: "live.rasterNow")
                    }
                    .buttonStyle(.bordered)
                }
                Text(verbatim: span)
                    .font(TypeLevel.footer.font)
                    .foregroundStyle(ColorRole.textMatt.color)
                    .monospacedDigit()
                Spacer(minLength: 0)
            }
            GeometryReader { space in
                timeline(width: max(space.size.width - Self.channelColumn, 200))
                    .padding(.leading, Self.channelColumn)
            }
            .frame(height: 18)
        }
        .padding(.horizontal, MetricsBoard.phone.margin)
        .padding(.bottom, MetricsBoard.phone.gutter)
    }

    private func pageButton(_ direction: GuideGridModel.Direction) -> some View {
        Button {
            model.page(direction, now: now)
        } label: {
            Image(systemName: direction == .back ? Glyph.back.name : Glyph.next.name)
        }
        .target()
        .accessibilityLabel(Text(appKey: direction == .back ? "raster.back" : "raster.forward"))
    }

    private var span: String {
        let form = Date.FormatStyle(date: .omitted, time: .shortened)
        return "\(model.windowStart.formatted(form)) – \(model.windowEnd.formatted(form))"
    }

    private func timeline(width: CGFloat) -> some View {
        let steps = Int(GuideGridModel.windowWidth / 1800)
        return ZStack(alignment: .topLeading) {
            ForEach(0..<steps, id: \.self) { index in
                let time = model.windowStart.addingTimeInterval(Double(index) * 1800)
                Text(verbatim: time.formatted(Date.FormatStyle(date: .omitted, time: .shortened)))
                    .font(TypeLevel.lowercased.font)
                    .monospacedDigit()
                    .foregroundStyle(
                        index.isMultiple(of: 2) ? ColorRole.text.color : ColorRole.textQuiet.color
                    )
                    .offset(x: width * CGFloat(index) / CGFloat(steps) + 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func nowLine(width: CGFloat, height: CGFloat) -> some View {
        if model.showsNow(now) {
            let portion = now.timeIntervalSince(model.windowStart) / GuideGridModel.windowWidth
            Rectangle()
                .fill(ColorRole.live.color)
                .frame(width: 2, height: height)
                .offset(x: MetricsBoard.phone.margin + Self.channelColumn + width * CGFloat(portion))
                .allowsHitTesting(false)
        }
    }

    // MARK: - Zeilen

    private func row(_ row: ProgramGrid.Row, width: CGFloat) -> some View {
        HStack(spacing: Self.cellSpacing) {
            Text(verbatim: row.channels.cleanName)
                .font(TypeLevel.footer.font)
                .foregroundStyle(ColorRole.text.color)
                .lineLimit(2)
                .frame(width: Self.channelColumn - Self.cellSpacing, alignment: .leading)
            HStack(spacing: Self.cellSpacing) {
                ForEach(row.cells) { cell in
                    checkbox(cell, channels: row.channels, width: width)
                }
            }
        }
        .frame(height: Self.lineHeight)
    }

    private func checkbox(
        _ cell: ProgramGrid.Cell, channels: Channel, width: CGFloat
    ) -> some View {
        let portion = cell.visibleDuration / GuideGridModel.windowWidth
        let span = max(width * CGFloat(portion) - Self.cellSpacing, 8)
        let recording =
            !cell.isGap && Catchup.isInArchive(channels, start: cell.start, now: now)
        return Button {
            tap(channels, cell)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: cell.title)
                    .font(TypeLevel.lowercased.font)
                    .foregroundStyle(cell.isGap ? ColorRole.textQuiet.color : ColorRole.text.color)
                    .lineLimit(2)
                if recording, span >= 110 {
                    Label {
                        Text(appKey: "live.rasterRecording")
                    } icon: {
                        Image(systemName: Glyph.history.name)
                    }
                    .font(TypeLevel.label.font)
                    .foregroundStyle(ColorRole.textMatt.color)
                }
                Spacer(minLength: 0)
            }
            .padding(6)
            .frame(width: span, height: Self.lineHeight, alignment: .topLeading)
            .background(
                cell.state == .running ? ColorRole.surfaceHigh.color : ColorRole.surface.color,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: cell.title))
    }
}
