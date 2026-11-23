import Foundation
import SourceProbe
import Testing

@testable import FeaturesPhone

/// **Every settings screen gets the same column** — AP7, 2026-09-23.
///
/// **The finding:** on an iPad Pro 13″ label and value stood up to 1700 points apart in every
/// settings row — the word on the left, the number far right, nothing
/// in between. Initially only ``SettingsScreen`` was capped.
///
/// **Why this is worth a check and not just a quick fix:** thirteen screens
/// with the same two-line change are thirteen chances to forget one —
/// and the one that is forgotten shows only on the device. Against exactly that this
/// project otherwise has a building block everywhere instead of a repetition.
///
/// **The check runs over the source**, as with the neighbors: what width a `View`
/// ends up occupying arises when drawing and cannot be queried without a running app in a
/// *regular* environment. The **rule** behind it can.
@Test("Every settings page puts its content in the column")
func settingsPagesUseContentColumn() throws {
    var withoutColumn: [String] = []
    for file in try SourceText.files(in: .featuresPhone, subfolder: "Settings")
    where file.relative == "Einstellungen/\(file.name)" {
        let content = file.content
        // Only pages with a scroll area of their own carry a column; sheets and building blocks
        // within them have none.
        guard content.contains("ScrollSurface") else { continue }
        guard !content.contains(".contentColumn(") else { continue }
        withoutColumn.append(file.name)
    }

    #expect(
        withoutColumn.isEmpty,
        """
        These settings pages scroll their content across the full width — on the iPad \
        label and value end up to 1700 points apart: \
        \(withoutColumn.sorted().joined(separator: ", "))
        """)
}
