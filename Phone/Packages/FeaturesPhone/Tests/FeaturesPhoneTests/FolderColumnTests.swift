import Foundation
import SourceProbe
import Testing

@testable import FeaturesPhone

/// **A folder list is text and does not need 1032 points** — AP7, 2026-09-23.
///
/// **The finding from the iPad:** A portal's category list shows twelve rows — on the left
/// the word, at the far right the arrow at x ≈ 2010 pixels, and in between about **1900
/// pixels of nothing**. The word and its arrow belong together and stood at
/// opposite ends of the screen.
///
/// **The same answer as for Settings**, and that is intentional: ``ContentColumn``
/// exists as of today, it caps at 700 points and centers. Solving two lists with the
/// same problem differently would be the duplication this project otherwise avoids
/// everywhere.
///
/// **Explicitly not built: two text columns.** The draft names them as a possibility.
/// A category list is read from top to bottom; two columns turn that into two
/// reading directions, and when more entries load — the list loads more — the
/// break jumps. The gain would be less black area at the bottom, the price an unclear
/// order. **If the black bothers anyone, it is a decision of its own.**
@Test("A portal's folder list sits in the content column")
func folderListSitsInColumn() throws {
    let content = try SourceText.read("PortalsView.swift", in: .featuresPhone)

    // **Both branches, not one.** ``PortalsView`` draws the folder list in two
    // places — with its own area above and without. A check that only demands "occurs"
    // would have been green with the first one, while the second — of all things
    // the plain category list from the finding — still ran across the full width.
    let locations = content.components(separatedBy: ".contentColumn(").count - 1

    #expect(
        locations >= 2,
        """
        PortalsView places its folder list in the column at \(locations) of two places — \
        on the iPad the category name and the arrow would otherwise be about 1900 pixels apart.
        """)
}
