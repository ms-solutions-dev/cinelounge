import Core
import DesignSystem
import Foundation
import ParentalControls
import SourceProbe
import Testing

@testable import Features

/// **An area that nobody finds** — AP26, 2026-09-11.
///
/// The content of Settings is a hand-written `switch` with by now eleven
/// branches. Three bugs are possible here, and **two of them are silent:**
///
/// * A new case **without a branch** — the compiler catches that ("switch must be
///   exhaustive"), and exactly that happened when "About" was added.
/// * A new area **without an entry in `door(forItem:)`** falls into the `default` and is
///   thereby **open** — it would silently fall out of parental controls.
/// * A **removed** case must be caught by the remembered area, otherwise
///   the store points to a state that the interface cannot display.
///
/// Plus the width calculation, which so far checked only the longest known entry: it
/// now runs over **all** cases.
/// **`@MainActor`, because the view's metrics live there.** The debug build let the
/// access through, the **release build** did not: "main actor-isolated static
/// property 'entryTextWidth' can not be referenced from a nonisolated autoclosure". For the
/// second time that day the release build was the stricter checker.
@MainActor
struct SettingsCompletenessTests {

    /// **Every area names a title and an icon** — and no two share one.
    @Test("Every section has its own title and its own icon")
    func everySectionIsDistinguishable() {
        let title = SettingsSection.allCases.map(\.titleKey)
        #expect(Set(title).count == title.count, "two sections share a title")
        #expect(title.allSatisfy { !$0.isEmpty })

        let character = SettingsSection.allCases.map(\.symbol)
        // **Two identical icons directly below each other cannot be told apart from three
        // meters** — the reasoning is at ``SettingsSection/symbol``.
        #expect(Set(character).count == character.count, "two sections share an icon")

        // And each of them is in the registry, with its meaning.
        for name in character where !Glyph.allNames.contains(name) {
            Issue.record("\(name) is not in Sinnbilder — see AP25")
        }
    }

    /// **Every area has a door — even if it is open.**
    ///
    /// **Until 2026-09-20 this test enshrined a hole** (AP40). It
    /// demanded "exactly two" and got exactly two, because `door(forItem:)` mapped everything else via
    /// a `default` to "open" — **including channel lists, portals and Live**.
    /// The shared door board lists all three as locked, with a reason ("This
    /// is where the switch for adult channels lives"), and on the phone that held too. The
    /// test was green, the promise in the text wrong, and both for three months.
    ///
    /// **Now it names five explicitly**, and `door(forItem:)` has no `default`
    /// any more: whoever adds an area must decide there **and** here.
    @Test("Sources and device sit behind the PIN")
    func theRightSectionsAreLocked() {
        let locked = SettingsSection.allCases.filter {
            LockedDoors.locked(SettingsView.door(forItem: $0))
        }
        #expect(
            Set(locked)
                == Set<SettingsSection>([
                    .playlists, .portals, .live, .childLock, .account, .profiles,
                ]),
            """
            Locked are: \(locked.map(\.rawValue).sorted().joined(separator: ", ")).
            Expected are the three source sections (a new list brings channels without \
            approvals; the adult-channel switch sits in “Live”) as well as \
            parental controls, media server and profiles (a profile switch lifts every \
            limit). What stays open is whatever lifts no limit — a lock that asks on \
            every touch gets switched off.
            """
        )

        // And the board also knows every named door.
        for area in SettingsSection.allCases {
            let door = SettingsView.door(forItem: area)
            #expect(
                LockedDoors.reason(door) != nil,
                "\(area.rawValue) names a door that does not exist: \(door)")
        }
    }

    /// **A removed area counts as never remembered.**
    ///
    /// What was stored survives refactors; an area that the enumeration no longer
    /// knows would be a state that the interface cannot display.
    @Test("A section that no longer exists leads back to the first")
    func aVanishedSectionIsCaught() {
        let store = InMemoryStore()
        try? store.set("gibtsNichtMehr", for: SettingsSection.storageKey)
        #expect(SettingsSection.load(from: store) == .playlists)

        // And a remembered one that exists comes back unchanged.
        SettingsSection.about.save(to: store)
        #expect(SettingsSection.load(from: store) == .about)
    }

    /// **The width calculation runs over all cases and all three languages.**
    ///
    /// The entries carry `lineLimit(1)`; too little space means an ellipsis,
    /// and on a TV those do not catch the eye of anyone who does not know the label
    /// anyway. The previous test held a **single measured number** against it
    /// (229 pt for "Değerlendirmeler") — it noticed nothing if a new area
    /// got a longer title.
    ///
    /// **What is read is the language catalog and not the test bundle.** The first attempt on
    /// 2026-09-11 used `String(localized:)`, and in the test bundle the app's catalog does not
    /// exist: what came back was the **key** (`settings.section.playlists`, 26 characters),
    /// and the test reported four areas as too wide that are not. A
    /// test that reports false positives gets switched off.
    @Test("Every section title has enough room in every language")
    func everyTitleFitsTheColumn() throws {
        let strings = try SourceText.catalogEntries(.tvCatalog)

        // **The factor comes from this project's measurement and not from a feeling.**
        // `SettingsViewTests` has always held: "Değerlendirmeler" measures 229 pt at
        // 29 pt semibold — sixteen characters, so **0.49 of the font size per character**.
        // The first attempt on 2026-09-11 set 0.62 "to be safe" and thereupon reported
        // four titles as too wide that fit when measured. An estimate that contradicts
        // one's own measurement is not safety but a false alarm.
        //
        // **What this test provides is a ripcord and not typography:** it
        // catches the title that is too long by half — not the one that is two points
        // too wide. For the second case there is the on-device test.
        let perCharacter = SettingsView.entrySize * 0.50
        var verified = 0

        for area in SettingsSection.allCases {
            guard let entry = strings[area.titleKey] as? [String: Any],
                let languages = entry["localizations"] as? [String: Any]
            else {
                Issue.record("\(area.titleKey) is missing from the language catalog")
                continue
            }
            for (language, value) in languages {
                guard let unit = (value as? [String: Any])?["stringUnit"] as? [String: Any],
                    let text = unit["value"] as? String
                else { continue }
                verified += 1
                let width = CGFloat(text.count) * perCharacter
                #expect(
                    width <= SettingsView.entryTextWidth,
                    """
                    \(text) (\(area.rawValue), \(language)) needs an estimated \
                    \(Int(width)) pt, available are \(Int(SettingsView.entryTextWidth)).
                    """
                )
            }
        }

        #expect(
            verified == SettingsSection.allCases.count * 3,
            "\(verified) titles were checked, three per section were expected")
    }
}
