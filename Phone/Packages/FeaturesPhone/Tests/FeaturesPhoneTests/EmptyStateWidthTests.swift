import Foundation
import SourceProbe
import Testing

@testable import FeaturesPhone

/// **A capped empty state must also center itself** — AP7, 2026-09-23.
///
/// **The finding came from the iPad.** "What are you looking for?" sat there not in the middle but
/// centered in a **393-point-wide column at the left edge** — the center was at
/// x ≈ 400 instead of 1032. On the phone that is never noticed: There the available width is
/// smaller than the cap, so the block fills everything anyway.
///
/// **The cause is half a sentence.** ``StateBlock`` caps at 400 points — the
/// only width cap of this kind in the app —, but does not say that the capped
/// block should stand centered in the available width. `.frame(maxWidth: 400)` alone
/// leaves the placement to the parent, and that pins to the left.
///
/// **The check runs over the source text and not over the image**, as with the other
/// build checks here: A position in the view tree cannot be queried without a running app,
/// the **rule** behind it can — whoever caps also centers.
@Test("Every capped state block centers itself in the available width")
func cappedStatesCenterThemselves() throws {
    let rows = try SourceText.read("StateBlock.swift", in: .featuresPhone)
        .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

    var withoutCenter: [Int] = []
    for (n, row) in rows.enumerated() where row.contains("maxWidth: 400") {
        let window = rows[n..<min(n + 3, rows.count)].joined(separator: "\n")
        if !window.contains("maxWidth: .infinity") { withoutCenter.append(n + 1) }
    }

    #expect(
        withoutCenter.isEmpty,
        """
        StateBlock.swift caps the block at 400 points in line \(withoutCenter.map(String.init).joined(separator: ", ")) \
        without centering it in the available width — on the iPad the empty state \
        then sits at the left edge.
        """)
}
