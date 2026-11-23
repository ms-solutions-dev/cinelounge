import Foundation
import SourceProbe
import Testing

@testable import Features

/// **One way of building and not two** — AP26, 2026-09-11.
///
/// The roadmap let this item lie until last, with a reason that
/// held: *"a half-completed unification across seven files is
/// worse than none — then there are two ways of building instead of one."* This check protects
/// against exactly that. It is the reason the rebuild went in **one** go and
/// not section by section.
///
/// **The finding was a list of numbers.** For one and the same thing — a row you can
/// select — `Settings/` and `Konten/` had four horizontal paddings
/// (24, 26, 30, 34), five vertical ones (12, 14, 15, 16, 18) and three outlines. Individually
/// you see none of them; together you see that it is not made from one mould.
struct RowBuildingBlocksTests {

    static let folder = ["Settings", "Accounts"]
    static let family = "RowComponents.swift"

    static func sources() throws -> [SourceFile] {
        try folder.flatMap { folder in
            try SourceText.files(in: .features, subfolder: folder)
        }.sorted { $0.url.path < $1.url.path }
    }

    /// **The capsule is drawn in one place.**
    ///
    /// It is the most visible part of the row and was the most widely scattered: In
    /// nine files there stood `in: Capsule()` with nine different paddings in front of it.
    @Test("Only the family draws the capsule")
    func oneOutline() throws {
        var foreignFiles: [String] = []
        for file in try Self.sources() where file.name != Self.family {
            let text = file.content
            if text.contains("in: Capsule()") { foreignFiles.append(file.name) }
        }
        #expect(
            foreignFiles.isEmpty,
            "These files draw their own capsule instead of `.einstellungsflaeche(…)`: \(foreignFiles)")
    }

    /// **No focus target builds its row itself.**
    ///
    /// What is searched for is the triad from which a row arises by hand: horizontal
    /// padding, vertical padding, own background. If it stands in the
    /// label of a button, a second way of building has arisen there.
    ///
    /// **Restricted to buttons and not to everything** — and that is no exception,
    /// but the rule itself: The family describes *rows you can select*.
    /// The subtitle sample under "Playback" has the same three lines in the source
    /// and is still not one: It shows how a subtitle looks in the film, therefore
    /// sits on black and takes no focus. A check that included it
    /// would need an exception list — and an exception list is the beginning of the second
    /// way of building.
    @Test("No button builds its own row")
    func oneConstruction() throws {
        let triad = try Regex(
            #"\.padding\(\.horizontal,[^)]*\)\s*\n\s*\.padding\(\.vertical,[^)]*\)"#)

        var selfBuilt: [String] = []
        for file in try Self.sources() where file.name != Self.family {
            let text = file.content
            for button in ButtonSite.all(in: text) {
                guard button.caption.contains(try: triad),
                    button.caption.contains(".background(")
                else { continue }
                let row = text[text.startIndex..<button.start].count(where: { $0 == "\n" }) + 1
                selfBuilt.append("\(file.name):\(row)")
            }
        }

        #expect(
            selfBuilt.isEmpty,
            """
            These buttons build their row themselves instead of via `.einstellungsflaeche(…)`:
            \(selfBuilt.joined(separator: "\n"))
            """)
    }

    /// **The dimensions are calculated and not set.**
    ///
    /// The same rule as with ``Tokens/Typography/lineHeight(for:)``: A copied
    /// number does not notice when the font changes. In this project exactly that
    /// has happened twice, and both times it looked like bad typography instead of
    /// a bug.
    @MainActor
    @Test("The row height follows the type")
    func heightFollowsTheFont() {
        // The section list on the left and the content on the right carry fonts of different
        // size, but the same surcharge — 62 against 59 pt.
        #expect(SettingsMetrics.height(forItem: 29) == 62)
        #expect(SettingsMetrics.height() == 59)
        #expect(SettingsMetrics.height(forItem: 29) == SettingsView.entryHeight)

        // And larger type becomes taller, not equally tall: A fixed line height
        // would cut off descenders here.
        #expect(SettingsMetrics.height(forItem: 38) > SettingsMetrics.height(forItem: 29))
    }
}

extension String {
    fileprivate func contains(try regex: Regex<AnyRegexOutput>) -> Bool {
        firstRange(of: regex) != nil
    }
}
