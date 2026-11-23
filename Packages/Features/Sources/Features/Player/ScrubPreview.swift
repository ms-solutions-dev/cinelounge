import Core
import DesignSystem
import SwiftUI

/// The preview image for the targeted position.
///
/// The server does not store single images but **sheets**: one large file with
/// many preview images in a grid. Exactly one cell of it is shown —
/// achieved by enlarging the whole sheet, shifting it and cropping it at the frame.
/// The calculation for this lives in ``Trickplay``; here it is only
/// converted into points.
///
/// Without information from the server this view does not appear at all — the place
/// that decides this is ``TransportBar``. An empty grey surface would be
/// worse than no preview: it looks as if loading had failed.
struct ScrubPreview: View {

    let trickplay: Trickplay
    let time: TimeInterval

    /// Fixed frame, so the preview does not change size while moving along the rail.
    /// The test server produces only the width 320 — shown half as large
    /// it could no longer be interpreted from three metres away.
    static let size = CGSize(width: 320, height: 180)

    var body: some View {
        let index = trickplay.thumbnailIndex(at: time)
        let cell = trickplay.cellFraction(forThumbnail: index)
        let sheet = geometry()

        // systemfarbe: Behind a preview image from the film, like the bars in the film.
        Color.black
            .frame(width: Self.size.width, height: Self.size.height)
            .overlay(alignment: .topLeading) {
                RemoteImage(url: trickplay.sheetURL(at: time), contentMode: .fill)
                    .frame(width: sheet.width, height: sheet.height)
                    .offset(
                        x: -(cell.x * sheet.width) - sheet.inset.width,
                        y: -(cell.y * sheet.height) - sheet.inset.height
                    )
            }
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: MetricsBoard.tv.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: MetricsBoard.tv.cardRadius, style: .continuous)
                    .stroke(ColorRole.text.color.opacity(0.5), lineWidth: 3)
            }
            .shadow(color: .black.opacity(0.75), radius: 26, y: 10)
    }

    /// Dimensions of the enlarged sheet and the offset by which the cell sits centred in the
    /// frame.
    ///
    /// It is enlarged to **fill** and not to fit: preview images of a
    /// home video in 4:3 format would otherwise have black stripes at the sides, and the
    /// preview would look different for every second title. The crop costs a little picture at the
    /// edges — for a preview that is of no consequence.
    private func geometry() -> (width: CGFloat, height: CGFloat, inset: CGSize) {
        let thumbWidth = CGFloat(max(1, trickplay.width))
        let thumbHeight = CGFloat(max(1, trickplay.height))

        let scale = max(Self.size.width / thumbWidth, Self.size.height / thumbHeight)
        let cellWidth = thumbWidth * scale
        let cellHeight = thumbHeight * scale

        return (
            width: cellWidth * CGFloat(trickplay.tileColumns),
            height: cellHeight * CGFloat(trickplay.tileRows),
            inset: CGSize(
                width: (cellWidth - Self.size.width) / 2,
                height: (cellHeight - Self.size.height) / 2
            )
        )
    }
}
