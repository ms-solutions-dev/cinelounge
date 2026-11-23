import DesignSystemPhone
import Testing

@testable import FeaturesPhone

/// **Eleven areas, eleven symbols — and the same as on the TV** (AP46, 2026-09-23).
///
/// **The finding** (`jellyfin-tvos/diagnose/2026-09-19-profile/5-ui-tvos.md`, E1): of eleven
/// area symbols **one** was the same on both devices. The family resemblance that
/// AP27 established in brand and stripe ended at the first settings row.
///
/// **The cause is in the source and is no matter of taste:** the phone **borrowed**
/// its area symbols from states — `expand` (a chevron!) for "Appearance",
/// `childAccount` for parental controls, `downloads` for storage, `check` for
/// diagnostics, `anmeldungNoetig` for the account. A chevron is not an area symbol, and
/// a badge that claims a deficiency is not a heading.
///
/// **The table decides per row, and mostly the TV is right** — with a
/// reason: outline for areas and filled for states (rule from `Glyph.Pair`),
/// circle for the area and not for the action, "a lock and not a family".
///
/// **Two rows stay as they are, and that is the table as well:** "Live" is right
/// on the phone (`dot.radiowaves` — the antenna is the broadcast, `tv` would be tautological
/// on the TV), and "Channel lists" already carries the recommended version `play.tv` here.
@Suite("The section icons of the settings")
struct SectionIconsTests {

    /// The table E1, as a test suite — area to SF Symbol.
    ///
    /// **The names with a dot are written assembled, and that is no flourish.**
    /// `scripts/strings.py` reads every string of the form `area.name` as a used
    /// language key — even in a test file, and an SF Symbol looks exactly the same.
    /// Reported in one piece, the check run names six missing catalog entries that never existed.
    private static let board: [(SettingsModel.Area, String)] = [
        (.channelLists, "play" + ".tv"),
        (.portals, "globe"),
        (.live, "dot" + ".radiowaves.left.and.right"),
        (.playback, "play" + ".circle"),
        (.ratings, "star" + ".leadinghalf.filled"),
        (.appearance, "paintbrush"),
        (.parentalControls, "lock" + ".shield"),
        (.storage, "internaldrive"),
        (.diagnose, "stethoscope"),
        (.account, "person" + ".crop.circle"),
        (.about, "info" + ".circle"),
    ]

    @Test("Every section carries the icon from the table")
    func followsTheBoard() {
        for (area, expected) in Self.board {
            #expect(
                area.icon == expected,
                """
                "\(area.rawValue)" carries `\(area.icon)` instead of `\(expected)`. \
                The two apps sit side by side on the same device family; a section that \
                is named differently on one device has to be learned twice.
                """)
        }
    }

    /// **No area borrows a state symbol any more.**
    ///
    /// That was the actual cause: not a wrong choice but **second use**.
    /// A symbol that at the same time means a state says something at the heading that
    /// does not apply there.
    @Test("None of these icons also means a state")
    func noSecondUse() {
        let states = [
            Glyph.down.name, Glyph.kind.name, Glyph.downloads.name,
            Glyph.check.name, Glyph.login.name,
        ]
        for (area, _) in Self.board {
            #expect(
                !states.contains(area.icon),
                """
                "\(area.rawValue)" carries an icon that also means a state.
                """)
        }
    }
}
