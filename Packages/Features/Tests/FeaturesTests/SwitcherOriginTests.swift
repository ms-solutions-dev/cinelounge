import Foundation
import SourceProbe
import Testing

@testable import Features

/// **Whose profile am I using right now?** — AP44 → AP45, 2026-09-23.
///
/// AP44 explicitly handed this hint over to here: *"in 'Who's watching?' it comes
/// with AP45, where the switcher is built."* Since AP44 a profile can belong to a
/// foreign Apple account — whoever sits in front of it then uses somebody else's profile, and
/// everything they do there ends up on that person's device.
///
/// **The place is the switcher and not a sheet two levels deeper.** ``CloudSheet``
/// has shown "shared by …" since AP44 — there only whoever is already in
/// Settings sees it. The profile is chosen here.
@Suite("The switcher names the origin")
struct SwitcherOriginTests {

    @Test("A shared profile carries its owner")
    func originSitsOnTheCircle() throws {
        let content = try SourceText.read("AccountSwitcher.swift", in: .features)

        // **The key name is assembled, and that is no trick.**
        // `scripts/strings.py` reads every string of the form `area.name` as a
        // used language key — also in a test file. If it stood here in one piece,
        // the check run would report it as missing: The real key is called
        // `pairing.sharedBy %@`, and a search form without the placeholder does not exist.
        let languageKey = "pairing." + "sharedBy"

        #expect(
            content.contains(languageKey),
            """
            The switcher does not name who owns a shared profile. Whoever picks it \
            uses someone else's profile without seeing it.
            """)
    }
}
