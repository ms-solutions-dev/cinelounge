import Core
import DesignSystemPhone
import SwiftUI

/// A row of posters below the detail page — "Similar" or "Parts of the series".
///
/// **Selecting opens, it does not play.** The same pattern as in the shelves of the
/// Home screen: whoever presses an unfamiliar poster wants to know what it is — not
/// that it starts right away.
///
/// **One component for both rows and not two.** They differ in the heading and in
/// nothing else; two views for that would be two places where the poster size can
/// drift apart.
struct SimilarShelf: View {

    /// Key of the heading.
    let title: String
    let tiles: [TileContent]
    let open: (TileContent) -> Void

    /// Where the long-press commands get their answer — see ``TileCommands``.
    ///
    /// **The finding of 2026-09-09:** The long press was attached in exactly three places —
    /// Home, portals, favorites — and was missing in library, search and **here**. A shelf
    /// that looks like the Home one and behaves differently is worse than one that
    /// looks different.
    var commandSource: (any DetailSource)?

    /// How a title stands in the downloads — per identifier, because every tile has its own.
    var downloadState: ((String) -> DownloadState?)?

    /// Opens the download sheet — `nil` if this page cannot do it.
    var load: ((TileContent) -> Void)?

    /// Reload after a change.
    var following: () -> Void = {}

    var body: some View {
        if !tiles.isEmpty {
            ShelfRow(
                title: AppLanguageSetting.text(.init(title)),
                tally: tiles.count.formatted(.number)
            ) {
                ForEach(tiles) { tile in
                    Button {
                        open(tile)
                    } label: {
                        PosterTile(content: tile)
                    }
                    .buttonStyle(.plain)
                    // **No "reset progress".** This shelf shows related items
                    // and not started ones; the command would take a title out of a shelf
                    // that is not even there — the same reasoning as for
                    // favorites.
                    //
                    // **And no origin from outside:** it is attached to the identifier
                    // (``PlaybackJob/origin(zu:)``), and a similar title can come from a
                    // different source than the page it appears on.
                    .tileCommands(
                        tile, origin: nil, source: commandSource, inHistory: false,
                        downloadState: downloadState.flatMap { $0(tile.id) }, load: load,
                        following: following)
                }
            }
        }
    }
}
