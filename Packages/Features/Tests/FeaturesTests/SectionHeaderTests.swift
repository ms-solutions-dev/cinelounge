import Foundation
import SourceProbe
import Testing

@testable import Features

/// **No header in the content is larger than the page title** — AP46, 2026-09-23.
///
/// **The first of the three causes** (`diagnose/2026-09-19-profile/5-ui-tvos.md`, B): The
/// hierarchy is upside down. ``SettingsHeader`` sets **57 points bold**, the page title
/// "Einstellungen" next to it **48** — and "Darstellung" stacks nine such headers, which
/// makes it about three screens long. The phone sets the group header in the **smallest**
/// type and the row large; exactly the other way round.
///
/// **One component in two roles, and that is the core.** The same ``SettingsHeader`` is in
/// 35 places sometimes the **section header** (one per section, at the very top) and
/// otherwise the **group header** (the subsections inside). As long as both look the same,
/// there is no hierarchy to see — only repetition.
///
/// **This check holds the "done when" line of the package**, literally: *"no section
/// carries a 57 pt header any more"*. It reads the size and not the look — what of that
/// arrives on screen only the eye sees, but that the largest type in the content is not
/// larger than the title above it is a number.
@Suite("The headers in Settings")
struct SectionHeaderTests {

    @Test("No header in the content has the title size")
    func noTitleInContent() throws {
        let content = try SourceText.read("SettingsView.swift", in: .features)

        // The body of the header — from its declaration to the end of `body`.
        guard let anchor = content.range(of: "struct SettingsHeader: View {") else {
            Issue.record("`SettingsHeader` no longer exists — this check needs adjusting then.")
            return
        }
        let bodyContent = content[anchor.upperBound...].prefix(900)

        #expect(
            !bodyContent.contains("Typography.title\n") && !bodyContent.contains("Typography.title)"),
            """
            The header in the content is 57 points again — larger than the page heading \
            at 48. “Darstellung” stacks nine of them and becomes three screens long.
            """)
    }
}
