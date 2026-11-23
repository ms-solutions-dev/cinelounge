import Foundation
import Testing

@testable import Features

/// **Where something is missing, the section list says so** — AP46, 2026-09-23.
///
/// **The finding** (`diagnose/2026-09-19-profile/5-ui-tvos.md`, third cause): On the TV
/// nothing says what is inside. The section list carried **a single** missing badge, only
/// for channel lists; the phone computes five.
///
/// **The source even had a justification for this**, and it is outdated:
/// ``SettingsSection/playlists`` called itself "the only one in which something can be
/// missing". That was true when there was the one badge.
///
/// **"Missing" means can be added, not broken** — that is the difference the whole badge
/// hangs on. Whoever sees it should know that there is something they **can** enter, not
/// that something is broken. That is why it carries the progress color and not the warning
/// color.
@Suite("What can be missing in a section")
struct SetupStateTests {

    /// **A set-up device carries a badge nowhere.** The costliest error would be a badge that
    /// is always there: It then says nothing any more, and one gets used to it before it is ever
    /// right.
    @Test("Fully set up — no marker")
    func allPresent() {
        let state = SetupState()
        for area in SettingsSection.allCases {
            #expect(
                !area.isMissingSomething(at: state),
                """
                “\(area.rawValue)” carries a marker although nothing is missing.
                """)
        }
    }

    /// **Only the source carries the badge, not Live** (product decision, 2026-09-28): With ⊕,
    /// Live looked as if it belonged to the sources above it.
    @Test("Without an IPTV list something is missing at the source, not at Live")
    func lacksChannelLists() {
        let state = SetupState(lacksChannelLists: true)
        #expect(SettingsSection.playlists.isMissingSomething(at: state))
        #expect(!SettingsSection.live.isMissingSomething(at: state))
    }

    @Test("Every state marks exactly its section")
    func eachOnItsOwn() {
        #expect(SettingsSection.portals.isMissingSomething(at: .init(lacksPortals: true)))
        #expect(SettingsSection.ratings.isMissingSomething(at: .init(lacksRatingsKey: true)))
        #expect(SettingsSection.account.isMissingSomething(at: .init(withoutAccess: true)))

        // And none marks a foreign one.
        #expect(!SettingsSection.playlists.isMissingSomething(at: .init(lacksPortals: true)))
        #expect(!SettingsSection.account.isMissingSomething(at: .init(lacksRatingsKey: true)))
    }

    /// **Sections in which nothing can be missing never carry a badge** — not even when
    /// everything else is missing. "Darstellung" always has a color, "Über" always a version
    /// number.
    @Test("Where nothing can be missing, nothing is shown")
    func alwaysComplete() {
        let emptyArea = SetupState(
            lacksChannelLists: true, lacksPortals: true,
            lacksRatingsKey: true, withoutAccess: true)
        for area in [SettingsSection.appearance, .playback, .storage, .diagnostics, .about] {
            #expect(
                !area.isMissingSomething(at: emptyArea),
                """
                Nothing can be missing from “\(area.rawValue)” at all.
                """)
        }
    }
}
