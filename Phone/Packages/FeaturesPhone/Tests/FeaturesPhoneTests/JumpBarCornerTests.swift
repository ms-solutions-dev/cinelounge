import Foundation
import SourceProbe
import Testing

@testable import FeaturesPhone

/// **Two targets must not lie in the same corner** — AP7, 2026-09-23.
///
/// **The finding came from the iPad, the error is older.** The round "to the top" button sits in the
/// overlay of the ``ScrollSurface`` at the bottom right; the A–Z jump bar has a
/// grab strip of `Metrics.target` (44 points) there, and in the `ZStack` it stands **after** the
/// scroll area — so it wins the hit testing. A tap on the middle of the button
/// did not scroll to the top but jumped to the letter "Z".
///
/// **On the phone the geometry is the same**, it just goes unnoticed there because both
/// targets lie closer together and one hits the bar anyway. The iPad pass
/// found an error that was always there — it is fixed for both devices.
///
/// **Stacking order does not solve it.** If the button were on top, it would cover "X", "Y" and
/// "Z". Two targets in one corner are separated only by location.
@Test("Where a jump bar stands, the scroll-to-top button does not sit in its corner")
func jumpBarAndButtonShareNoCorner() throws {
    var disputes: [String] = []
    for file in try SourceText.files(in: .featuresPhone) {
        // The building blocks themselves do not count — there the construction is defined, not its use.
        guard file.name != "JumpBar.swift",
            file.name != "ScrollSurface.swift"
        else { continue }

        let content = file.content
        guard content.contains("JumpBar("), content.contains("ScrollSurface(") else { continue }
        guard !content.contains("scrollToTopCorner: .bottomLeading") else { continue }
        disputes.append(file.name)
    }

    #expect(
        disputes.isEmpty,
        """
        These views draw a jump bar and a scroll surface together but leave the \
        scroll-to-top button in the corner of the bar: \(disputes.joined(separator: ", "))
        """)
}
