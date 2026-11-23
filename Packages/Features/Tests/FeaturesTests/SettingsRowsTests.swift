import Foundation
import SourceProbe
import Testing

@testable import Features

/// **How many places still build their settings row themselves?** — AP46, 2026-09-23.
///
/// **The finding AP46 works off** (`diagnose/2026-09-19-profile/5-ui-tvos.md`, B):
/// ``SettingsMetrics`` unified the *dimensions* in AP26 but not the meaning — switch,
/// selection, navigation and action have been the same pill since, and twenty private
/// helper functions in nine files go on building their row themselves.
///
/// **This check is at the same time the progress meter.** It counts the places that call
/// `settingsSurface(…)` **directly** instead of taking one of the components from
/// ``Einstellungszeilen``. With every converted section the number drops, and the limit
/// here drops with it — until it reaches zero.
///
/// **It is sharp upward and not downward.** Whoever converts a row should be able to lower
/// the number without the check getting in the way; whoever pulls in a **new** hand-built
/// row should see red immediately. A check for equality would demand number upkeep at every
/// step and would be switched off after the third time.
@Suite("The settings rows")
struct SettingsRowsTests {

    /// The state on 2026-09-24: **20** places in the settings, it started at 50.
    ///
    /// **The way there is AP46, item "All thirteen sections converted".** What is left is
    /// spread over `OtherSettings` (6), `Regalquellen` (4), `LiveSettings` (4),
    /// `PortalSettings` (3), `AboutSettings` (2), `DiagnosticsSettings` (2).
    ///
    /// **The rest are not rows** (looked at on 2026-09-24), and that is why this number does
    /// not fall further before "direction B" is built. What is there is of four kinds:
    ///
    /// * **Pills in horizontal rows** — jump markers, "All on/off", the group switch in
    ///   ``LiveSettings``. A ``SwitchRow`` is full width; as a pill in a row it would need
    ///   a second form, and that would have **one** consumer.
    /// * **Image previews** — color swatches, the 240 × 144 app-icon tile, posters. The item
    ///   "right column" decides about them.
    /// * **Glyph buttons** (``RowKind/character``) — an arrow, an eye, no word.
    /// * **The innards of ``ColumnChoice``**, and that is the interesting case: It is itself
    ///   already a piece of direction B — list · rows · the choice on the right —, just older
    ///   than these components. Its rows therefore set the surface themselves.
    ///
    /// **The roadmap item is called "no section builds a row itself any more"**, and that is
    /// reached wherever there are rows. This number measures more than the item; from here on
    /// it is a **cap** like the one for the sheets and no longer a path.
    ///
    /// **2026-09-25: 20 → 15.** With the regrouping five fell, and each of them was a row that
    /// had merely disguised itself as a pill: the color swatch (now ``ToggleRow``), the
    /// provider tiers and the state view (``DisclosureRow``), the home-made row with a count in
    /// "Darstellung" and the register in "Live" that pointed to nothing. The four switches in
    /// "Live" are ``SwitchRow``s; their factory stays for the sports grid, where they really
    /// are pills in a row.
    private static let limit = 15

    /// The **sheets** have a limit of their own, and it does not drop to zero.
    ///
    /// **Found on 2026-09-23 during the first rework:** The counter stood at 64, but only 46 of
    /// them are in `Settings/`. The other **18** are in `Konten/` — PIN sheet, profile sheet,
    /// curtain, migration. Those are modal windows with two buttons and a field, not lists of
    /// rows; they take ``settingsSurface`` as **shared look**, so that a button in the
    /// sheet looks like a button next to it. A ``DisclosureRow`` will never stand there.
    ///
    /// **Two numbers instead of one, because one number would have missed the goal.** A joint
    /// limit would never reach zero, and a check whose goal is unreachable gets switched off the
    /// third time — exactly what the overall check above wants to avoid. For the sheets the
    /// number is a **cap** and not a path: It must not rise, it need not fall.
    ///
    /// **Plus three from the first setup** (AP88, 2026-11-16): the steps in `Setup/` are full-screen
    /// pages with a field and two buttons, the same kind as the sheets in `Accounts/`, and they
    /// borrow the same surface for the same reason.
    private static let sheetLimit = 21

    @Test("No new hand-built rows")
    func notMoreThanBefore() throws {
        var sections = 0
        var sheets = 0
        var perFile: [String: Int] = [:]

        for target in try SourceText.files(in: .features) {
            // **The components themselves do not count** — they are the target and not the rest.
            guard target.name != "SettingsRows.swift" else { continue }
            let match = target.content.components(separatedBy: ".settingsSurface(").count - 1
            guard match > 0 else { continue }
            if ["Accounts", "Setup"].contains(target.url.deletingLastPathComponent().lastPathComponent) {
                sheets += match
            } else {
                sections += match
                perFile[target.name] = match
            }
        }

        let largest = perFile.sorted { $0.value > $1.value }.prefix(3)
            .map { "\($0.key) \($0.value)" }.joined(separator: ", ")

        #expect(
            sections <= Self.limit,
            """
            \(sections) places in Settings set their row surface themselves, \
            \(Self.limit) are allowed. The largest: \(largest). A new hand-built \
            row is a switch that looks like a choice — exactly the finding \
            AP46 pays off. Take a building block from `SettingsRows.swift`.
            """)

        #expect(
            sheets <= Self.sheetLimit,
            """
            \(sheets) places in `Konten/` set their surface themselves, \(Self.sheetLimit) \
            are allowed. A sheet is not a list of rows, but this number \
            should not grow either: whatever is newly created there belongs either on a \
            building block or on one of the existing buttons in the sheet.
            """)
    }

    /// Sections that are **completely** converted — and must stay so.
    ///
    /// **The total alone is not enough as a guard.** It is sharp upward, and that is right; but
    /// it permits saving two rows in one place and building two new ones by hand in an already
    /// converted section. The sum would stay the same, the work would be undone, and nobody
    /// would have noticed.
    ///
    /// **Every converted section is added here** — until all thirteen are there and the total
    /// is zero. Then both checks say the same thing, and this one may go.
    private static let converted = [
        "PlaybackSettings.swift", "PlaylistSettings.swift", "SubtitleSettings.swift",
        "LanguageSettings.swift", "ProfileSettings.swift",
    ]

    @Test("A converted section no longer builds a row itself")
    func noRegression() throws {
        for name in Self.converted {
            let content = try SourceText.read("Settings/" + name, in: .features)
            let match = content.components(separatedBy: ".settingsSurface(").count - 1
            #expect(
                match == 0,
                """
                \(name) sets a row surface itself again in \(match) places. \
                The section had been converted — take a building block from \
                `SettingsRows.swift` instead of `.einstellungsflaeche(…)`.
                """)
        }
    }
}
