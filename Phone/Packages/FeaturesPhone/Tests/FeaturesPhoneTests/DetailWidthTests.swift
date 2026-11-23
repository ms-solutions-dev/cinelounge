import Foundation
import SourceProbe
import Testing

@testable import FeaturesPhone

/// **The detail page on the iPad: reading column and main button** — AP7, 2026-09-23.
///
/// **The finding checked against here.** On an iPad Pro 13″ (1032 × 1376 points)
/// the detail page was a phone page stretched to full width: descriptions
/// ran over about 992 points with **about 120 characters per line** (60–80 read well),
/// and the "Play" bar was **945 points** wide, because ``DesignSystemPhone/LoudButtonStyle``
/// sets `maxWidth: .infinity`.
///
/// **The check runs over the source and not over the picture** — the same form as
/// `LeerzustandBreiteTests` and `SprungleisteEckeTests`: a position in the view tree cannot
/// be queried without a running app, but the **rule** behind it can.
@Suite("Detail page widths")
struct DetailWidthTests {

    /// Whether a centering frame stands in the next `window` lines from `n`.
    private static func centersItself(_ rows: [String], from n: Int, window: Int = 3) -> Bool {
        rows[n..<min(n + window, rows.count)].joined(separator: "\n")
            .contains("maxWidth: .infinity")
    }

    private static func isComment(_ row: String) -> Bool {
        row.trimmingCharacters(in: .whitespaces).hasPrefix("//")
    }

    /// **The rule that is really at stake: whoever caps also centers.**
    ///
    /// **The error already occurred twice in this app.** ``StateBlock`` capped at
    /// 400 points without centering — "What are you looking for?" then sat centered in a
    /// 393-point column at the **left** edge, midpoint at x ≈ 400 instead of 1032
    /// (see `LeerzustandBreiteTests`). `.frame(maxWidth:)` alone only says how wide a
    /// block may get at most; **it leaves its position to the parent, and that pins to the
    /// left.** On the phone this never shows, because the available width there is smaller
    /// than any of these caps.
    ///
    /// **The reading width is checked in all views, not just in the detail page.**
    /// ``MetricClass/readingWidth`` is a cap for running text *in a wider
    /// container* — exactly the situation where the pinning becomes visible. Wherever someone
    /// sets it in future, the centering frame must stand beside it.
    ///
    /// **And it must be set at least once.** Otherwise this check would be vacuously
    /// satisfied and green while the description ran over 992 points again — exactly the
    /// state before 2026-09-23.
    @Test("Every reading column caps its width and centers itself")
    func readingColumnsCapAndCenterThemselves() throws {
        var capped: [String] = []
        var withoutCenter: [String] = []

        for file in try SourceText.files(in: .featuresPhone) {
            let rows = file.content
                .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

            for (n, row) in rows.enumerated()
            where row.contains("MetricClass.readingWidth") && !Self.isComment(row) {
                let location = "\(file.name):\(n + 1)"
                capped.append(location)
                if !Self.centersItself(rows, from: n) { withoutCenter.append(location) }
            }
        }

        #expect(
            !capped.isEmpty,
            """
            No view caps its body text at MetricClass.readingWidth any more — on a 13″ iPad \
            Pro the descriptions would run across roughly 992 points with about 120 \
            characters per line.
            """)
        #expect(
            withoutCenter.isEmpty,
            """
            These places cap the width at the reading width without centering the block in \
            the available width: \(withoutCenter.joined(separator: ", ")). A cap without \
            `.frame(maxWidth: .infinity)` next to it pins the block to the leading edge.
            """)
    }

    /// **The detail page's main button carries its cap.**
    ///
    /// ``DesignSystemPhone/LoudButtonStyle`` sets `maxWidth: .infinity` — in a row of
    /// 393 points that is a button, in one of 992 a bench. The cap is not applied in the
    /// style (it is used in 54 places, most of them sheets and lists), but at the
    /// one place that knows it is the main thing of the page.
    @Test("The detail page Play button is capped")
    func primaryButtonIsCapped() throws {
        let rows = try SourceText.read("DetailView.swift", in: .featuresPhone)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var loud: [Int] = []
        var withoutCap: [Int] = []
        for (n, row) in rows.enumerated() where row.contains("buttonStyle(.loud)") {
            loud.append(n + 1)
            let window = rows[n..<min(n + 8, rows.count)].joined(separator: "\n")
            if !window.contains(".primaryButtonWidth()") { withoutCap.append(n + 1) }
        }

        #expect(!loud.isEmpty, "DetailView.swift no longer draws a loud button.")
        #expect(
            withoutCap.isEmpty,
            """
            DetailView.swift draws a loud button without `.primaryButtonWidth()` at line \
            \(withoutCap.map(String.init).joined(separator: ", ")) — on the iPad the bar \
            becomes 945 points wide.
            """)
    }

    /// **The shared style stays as it was — that was the decision.**
    ///
    /// The cap could also have gone into ``DesignSystemPhone/LoudButtonStyle``, and that would have been
    /// wrong: `.loud` and `.quiet` appear in 54 places in 28 files, almost all
    /// in sheets, set-up steps and state views, where the button **is supposed to fill
    /// its row**. This line records the decision: the style package still
    /// has `maxWidth: .infinity` and no size class.
    @Test("The shared button style carries no cap")
    func sharedStyleStaysUncapped() throws {
        let content = try SourceText.read("ButtonStyles.swift", in: .designSystemPhone)

        #expect(
            content.contains("maxWidth: .infinity"),
            "The shared style no longer fills its row — the button would then sit crooked in every sheet.")
        #expect(
            !content.contains("SizeClass"),
            """
            DesignSystemPhone/ButtonStyles.swift now decides by size class. The package \
            promises fixed dimensions in its header (393 × 852); a case distinction inside it \
            is exactly the mistake MetricClass was introduced to avoid — and it would hit \
            all 54 buttons, including every one in a sheet and every second one in a row.
            """)
    }

    /// **The modifier itself keeps the rule**, otherwise it would only move the error by
    /// one file.
    @Test("The primary button width caps and centers")
    func primaryButtonWidthAlsoCenters() throws {
        let rows = try SourceText.read("PrimaryButtonWidth.swift", in: .featuresPhone)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        #expect(
            rows.contains(where: { $0.contains("func primaryButtonWidth()") }),
            "Components/PrimaryButtonWidth.swift offers no `primaryButtonWidth()` modifier.")

        var withoutCenter: [Int] = []
        for (n, row) in rows.enumerated() where !Self.isComment(row) {
            guard row.contains("maxWidth:"), !row.contains("maxWidth: .infinity") else { continue }
            if !Self.centersItself(rows, from: n) { withoutCenter.append(n + 1) }
        }

        #expect(
            withoutCenter.isEmpty,
            """
            Components/PrimaryButtonWidth.swift caps the width at line \
            \(withoutCenter.map(String.init).joined(separator: ", ")) without centering.
            """)
    }
}
