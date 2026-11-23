import Foundation
import SourceProbe
import Testing

@testable import Features

/// **The section header carried two roles in one shape** — AP46, 2026-09-24.
///
/// ``SettingsHeader`` appeared in thirty places: in six as a **section** name, otherwise as
/// a **group** name inside. Both looked the same, so there was no hierarchy to see, only
/// repetition — the section name is already on the left in the list.
@Suite("The section breadcrumb")
struct SectionBreadcrumbTests {

    /// **No section names itself at the top any more.**
    ///
    /// That is the done condition of this item, and it can be recounted in the source: A
    /// `SettingsHeader("settings.section.…")` is a section header, and ``SettingsView`` now
    /// sets that once as a ``AreaBreadcrumb``.
    ///
    /// **Four keys in the same namespace are allowed nonetheless** and are named here:
    /// `homePortals` and `homeChannels` are sub-screens of Appearance, `filmography` and `mal`
    /// (AP68) are sections in the ratings area. None of them is a ``SettingsSection`` — the
    /// namespace `settings.section.*` does not say "section".
    @Test("No section carries its own section header any more")
    func noSectionHeaderAnymore() throws {
        let isAllowed = ["homePortals", "homeChannels", "filmography", "mal"]
        var found: [String] = []

        for target in try SourceText.files(in: .features, subfolder: "Settings") {
            let content = target.content
            for row in content.split(separator: "\n") {
                guard row.contains("SettingsHeader(\"settings.section.") else { continue }
                let name =
                    row
                    .components(separatedBy: "settings.section.").last?
                    .components(separatedBy: "\"").first ?? ""
                guard !isAllowed.contains(name) else { continue }
                found.append("\(target.name): \(name)")
            }
        }

        #expect(
            found.isEmpty,
            """
            \(found.joined(separator: ", ")) — a section names its own name at the \
            top. That name is on the left in the list; `SettingsView` sets the location once \
            as `Bereichskrume`.
            """)
    }

    /// **Every group has a name in the catalog**, otherwise the breadcrumb would show its raw
    /// value.
    @Test("All four groups carry a language key")
    func allGroupsHaveAName() throws {
        let content = try SourceText.read(.tvCatalog) + SourceText.read(.wordingCatalog)

        for group in SettingsSection.Group.allCases {
            // **Split so that no part looks like a key itself.**
            // `scripts/strings.py` reads every string with a dot in the middle as a used language
            // key, and here it is only a search pattern. Whoever splits at the **last** dot leaves two
            // words joined by a dot at the front — and those are then reported as a missing key. The
            // counterexample is **not written out as code** here, because it would trigger the same
            // error again; that happened to me on 2026-09-24 as well.
            let languageKey = "settings" + ".group." + group.rawValue
            #expect(
                content.contains("\"\(languageKey)\""),
                "\(languageKey) is missing from the catalog — the breadcrumb would otherwise show the raw value"
            )
        }
    }

    /// **Fourteen sections, seven with an explanatory sentence** — and the enumeration is
    /// complete.
    ///
    /// **Fourteen since 2026-09-25** (product decision 1): Subtitles and language were added as
    /// sections of their own, both with a sentence — their name alone does not say who the
    /// choice applies to. The profiles carry their sentence in the profile management itself.
    ///
    /// A missing line in ``SettingsSection/hintKey`` would not be a translation error:
    /// Swift requires all cases in a `switch` over an enumeration, so it shows up at compile
    /// time. What is checked here is the **count** — so that a sentence that silently
    /// disappears gets noticed.
    @Test("Seven sections carry an explanatory sentence")
    func filterWithSentence() {
        let withSentence = SettingsSection.allCases.filter { $0.hintKey != nil }
        #expect(withSentence.count == 7)
        #expect(SettingsSection.allCases.count == 14)
    }
}
