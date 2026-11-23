import CoreGraphics
import SwiftUI

/// A cell from an image sheet — the chapter image from the trickplay grid.
///
/// **A building block of its own next to ``RemoteImage`` and no extension of it.** The
/// ordinary one loads **one** address and displays it; here ten views load **one** address
/// and display ten different cutouts from it. Whoever squeezes that into one block gives it
/// two modes of operation and has to say at every call site which applies.
///
/// **The sharpness is that of the sheet and no more.** Jellyfin generates trickplay at 320
/// pixels width; drawn at 200 points that is barely half the drawing density of a triple-
/// scale screen. That is the trade: a slightly soft still frame against an empty box. A
/// sharper one does not exist — the server has none.
public struct AtlasImage: View {

    private let sheet: URL?
    private let columns: Int
    private let rows: Int
    private let column: Int
    private let row: Int
    private let width: CGFloat

    @State private var image: CGImage?

    public init(
        sheet: URL?, columns: Int, rows: Int, column: Int, row: Int, width: CGFloat
    ) {
        self.sheet = sheet
        self.columns = columns
        self.rows = rows
        self.column = column
        self.row = row
        self.width = width
    }

    public var body: some View {
        Color.clear
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                } else {
                    ColorRole.surface.color
                }
            }
            .clipped()
            .task(id: identifier) {
                guard let sheet else { return }
                let points = ImageSizes.pixels(
                    forItem: width, reference: ImageSizes.reference)
                image = await ImageLoader.shared.slice(
                    sheet, columns: columns, rows: rows, column: column, row: row,
                    pixels: points)
            }
    }

    /// Sheet **and** cell, because ten views share one address. Without the cell in the key the
    /// second mark would not reload — `task(id:)` would see no change.
    private var identifier: String {
        "\(sheet?.absoluteString ?? "")#\(column)x\(row)"
    }
}
