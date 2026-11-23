import Foundation
import Testing

@testable import FeaturesPhone

/// The search across the settings — **and what can be checked without an app bundle.**
///
/// **The caveat belongs at the start, because it determines half of the checks.**
/// Under `swift test` there is no app bundle; `String(localized:)` returns the
/// **key** there instead of the text. A check that types "untertitel" and expects a
/// hit would thus test not the search but the presence of the catalog —
/// and would fail outside the app. The same lesson as on 2026-09-06 with the value column.
///
/// **What is checked is therefore what is true without translation:** the shape of the catalog, the
/// ranks of the result list (via key texts), the folding and the lower bound. Whether
/// "Subtitles" finds the subtitle size is decided by the screen — and
/// `scripts/catalog.py` decides whether every setting is in the catalog at all.
@Suite("Settings catalog")
struct SettingsCatalogTests {

    /// **A duplicate key is not a cosmetic flaw but a crash.** The
    /// result list is a `ForEach` over ``CatalogEntry/id``, and two equal
    /// identifiers in it are a runtime error in SwiftUI. The catalog is composed of two
    /// lists — the eleven areas and the rows —, and exactly at the seam it can
    /// arise without either of the two lists being wrong on its own.
    @Test("No key appears twice in the catalog")
    func noDuplicates() {
        let titles = SettingsCatalog.all.map(\.title)
        let onlyOnce = Set(titles)
        #expect(
            titles.count == onlyOnce.count,
            "Duplicate: \(titles.filter { title in titles.count(where: { $0 == title }) > 1 })")
    }

    /// **Every area is a hit itself.** Typing "Diagnostics" and finding nothing
    /// because only the rows *in* the diagnostics are in the catalog would be the wrong
    /// half — and it would be the more likely error: rows are entered because one is
    /// building them right now; the areas already existed.
    @Test("All eleven areas are in the catalog")
    func allSections() {
        for area in SettingsModel.Area.allCases {
            #expect(
                SettingsCatalog.all.contains { $0.title == area.titleKey },
                "\(area.rawValue) is missing")
        }
    }

    /// **One letter is not a search term.** With one character almost every entry would match,
    /// and the list would be longer than the root it replaces — a search that
    /// shows everything at the first keystroke has already lost.
    /// **The switch "ASS subtitles as plain text" is now on the phone too**
    /// (decision 27, C13) — and whoever searches for "ASS" finds it.
    @Test("The ASS toggle can be found")
    func assToggle() {
        #expect(
            SettingsCatalog.match(zu: "ASS").contains {
                $0.title == "settings.plainSubtitlesToggle"
            })
    }

    @Test("Below two characters nothing is searched")
    func lowerBound() {
        #expect(SettingsCatalog.match(zu: "").isEmpty)
        #expect(SettingsCatalog.match(zu: "a").isEmpty)
        #expect(SettingsCatalog.match(zu: "   ").isEmpty)
    }

    /// **The beginning beats the middle.** Whoever types "live" almost always means the
    /// Live area and not a row whose footer contains the word. Without the
    /// ranking the order of the catalog would show — and that is a filing order, not an
    /// answer.
    ///
    /// Without a bundle the "text" is the key itself; `settings.live` starts with
    /// `settings.live`, `settings.lists.add` does not contain it. That lets the
    /// rank be checked without presupposing a translation.
    @Test("A front match comes first")
    func ranking() {
        let match = SettingsCatalog.match(zu: "settings.live")
        #expect(!match.isEmpty, "settings.live must find something")
        #expect(
            match.first?.title.hasPrefix("settings.live") == true,
            "A title match comes first, found: \(match.first?.title ?? "nothing")")
    }

    /// **The incidental text is searched too.** The footer under a row is the
    /// synonym list that nobody had to maintain — it has long been in the catalog and was
    /// simply never read. Without it "tabs" would not find Portals, although exactly that
    /// is written there.
    @Test("A keyword finds its entry")
    func keyword() {
        let match = SettingsCatalog.match(zu: "settings.portals.enabled.footnote")
        #expect(
            match.contains { $0.title == "settings.portals.enabled" },
            "The footnote belongs to the toggle above it")
    }

    /// **Words that are the same in every language stand literally.** Keeping "M3U" and
    /// "Xtream" as language keys would mean translating the same word three times.
    @Test("An untranslated term finds its entry")
    func term() {
        #expect(
            SettingsCatalog.match(zu: "m3u").contains { $0.title == "settings.addPlaylist" })
        #expect(
            SettingsCatalog.match(zu: "EPG").contains { $0.title == "settings.lists.guide" })
    }

    /// **Upper case, lower case and with marks above are the same word.** Whoever searches for "Türkçe" rarely
    /// types the diacritic.
    @Test("Folding ignores case and the marks above letters")
    func folding() {
        #expect(SettingsCatalog.fold("Türkçe") == SettingsCatalog.fold("turkce"))
        #expect(SettingsCatalog.fold("  Diagnose ") == SettingsCatalog.fold("DIAGNOSE"))
    }

    /// **What is not there is not invented.** A search that shows something for every term
    /// is no search — and the viewer taps a hit that takes them
    /// somewhere other than they wanted.
    @Test("A term without a counterpart finds nothing")
    func nothing() {
        #expect(SettingsCatalog.match(zu: "zzzqqq").isEmpty)
    }

    /// **Structure as on the TV** (AP58 R7, decision 1): Account (media server)
    /// under Sources and first, Live under Watching. Until R7 the account was under About and
    /// Live under Sources.
    @Test("The areas follow the TV groups")
    func outlineAsOnTV() {
        #expect(SettingsModel.Area.account.group == .sources)
        #expect(SettingsModel.Area.allCases.first == .account)
        #expect(SettingsModel.Area.live.group == .watching)
        // "About" has been under Device since AP59 N7 — three groups instead of four.
        #expect(SettingsModel.Area.about.group == .device)
    }
}
