import Foundation
import SourceProbe
import SwiftUI
import Testing

@testable import FeaturesPhone

/// **The detail page's head side by side** — AP7, 2026-09-24.
///
/// **What is guarded here is a rebuild across two files.** ``HeaderSpace`` puts the text column
/// next to the poster in *regular* and becomes as tall as its content for that;
/// ``DetailView`` draws the same block in *compact* under the head and the trailer in
/// its place. The roadmap warned that a half rebuild would be worse than
/// none — and it is exactly the half states that these checks turn red:
///
/// - The head flips, the trailer does not: the page jumps when the trailer starts.
/// - The head flips, the block below does not: the title stands twice, or not at all.
/// - The column stands, the old reading cap too: at 720 it is wider than the column at
///   520, never takes effect, and its comment claims something false.
///
/// **The numbers are calculated, the arrangement is read from the source** — the same form
/// as ``DetailWidthTests``: a position in the view tree cannot be queried without a
/// running app, but the **rule** behind it can.
@Suite("Detail page header")
struct DetailHeaderTests {

    /// The lines of a source file **without** pure comment lines — an explanation may
    /// name the old number, it is the reason why the new one stands there.
    private static func code(_ name: String) throws -> [String] {
        try SourceText.read(name, in: .featuresPhone)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }

    /// The body of a function, from its header line to the next declaration at the
    /// same indentation.
    private static func bodyContent(_ rows: [String], from header: String) -> [String] {
        guard let start = rows.firstIndex(where: { $0.contains(header) }) else { return [] }
        let end =
            rows[(start + 1)...].firstIndex(where: {
                $0.hasPrefix("    private func") || $0.hasPrefix("    func")
                    || $0.hasPrefix("    private var") || $0.hasPrefix("    @ViewBuilder")
            }) ?? rows.count
        return Array(rows[start..<end])
    }

    /// **The column exists only in regular** — and `nil` calculates like compact.
    ///
    /// `nil` is no theory: a preview or a check without an environment delivers it.
    /// The phone layout is the right one there, because it works at any width.
    @Test("The column is part of the header only in regular")
    func columnOnlyInRegular() {
        #expect(HeaderSpaceMetrics.hasColumn(.regular))
        #expect(!HeaderSpaceMetrics.hasColumn(.compact))
        #expect(!HeaderSpaceMetrics.hasColumn(nil))
    }

    /// **The trailer takes the height of the head that it replaces** (step 3).
    ///
    /// In compact it stays the fixed number, even if a measurement exists — there the
    /// head is fixed. In regular the measured height applies, but never less than the lower bound
    /// of the head; without a measurement (trailer before the first frame) likewise the lower bound.
    @Test("The trailer is as tall as the header")
    func trailerFollowsTheHeader() {
        #expect(HeaderSpaceMetrics.trailerHeight(.compact, measured: 460) == HeaderSpaceMetrics.height)
        #expect(HeaderSpaceMetrics.trailerHeight(nil, measured: 460) == HeaderSpaceMetrics.height)
        #expect(HeaderSpaceMetrics.trailerHeight(.regular, measured: 460) == 460)
        #expect(HeaderSpaceMetrics.trailerHeight(.regular, measured: 120) == HeaderSpaceMetrics.height)
        #expect(HeaderSpaceMetrics.trailerHeight(.regular, measured: nil) == HeaderSpaceMetrics.height)
    }

    /// **The coupling across the file boundary** — the trailer asks the same place.
    ///
    /// The calculation above is correct, but of no use if ``DetailView`` does not call it
    /// and keeps taking the fixed number. That was exactly the state before the rebuild, and
    /// it would be back after a half rebuild.
    @Test("The detail page draws the trailer with the header height")
    func trailerAsksForHeaderHeight() throws {
        let rows = try Self.code("DetailView.swift")
        let fixed = rows.enumerated()
            .filter { $0.element.contains("HeaderSpaceMetrics.height") }
            .map { "DetailView.swift:\($0.offset + 1)" }

        #expect(
            fixed.isEmpty,
            """
            The detail page uses the fixed header height: \(fixed.joined(separator: ", ")). In \
            regular the header is as tall as its content — a trailer with a fixed height makes \
            the page jump on start. Ask HeaderSpaceMetrics.trailerHeight(_:measured:) instead.
            """)
        #expect(
            rows.contains { $0.contains("HeaderSpaceMetrics.trailerHeight(") },
            "The detail page no longer asks HeaderSpaceMetrics.trailerHeight(_:measured:).")
    }

    /// **Head and page flip at the same point.**
    ///
    /// ``HeaderSpace`` takes the column, ``DetailView`` omits the block below — both
    /// via ``HeaderSpaceMetrics/hasColumn(_:)``. Had one of the two files queried the
    /// size class itself, the condition would drift apart at the next rebuild.
    @Test("Header and page ask the same switch")
    func sameSwitch() throws {
        for name in ["HeaderSpace.swift", "DetailView.swift"] {
            let rows = try Self.code(name)
            #expect(
                rows.contains { $0.contains("HeaderSpaceMetrics.hasColumn(") },
                "\(name) does not decide on the column via HeaderSpaceMetrics.hasColumn(_:).")
        }
    }

    /// **The head block no longer carries a reading cap** (step 4).
    ///
    /// In regular it sits in the column, and at 520 points that is narrower than the
    /// cap of 720 — it never took effect there. In compact it never took effect anyway. It would
    /// only have remained as a claim, and its justification ("the description
    /// ran over 992 points") would be false above a block that can no longer do that.
    @Test("The header block carries no reading cap")
    func headerBlockWithoutReadingCap() throws {
        let block = Self.bodyContent(try Self.code("DetailView.swift"), from: "func headerBlock(")

        #expect(!block.isEmpty, "DetailView.swift no longer has `headerBlock(_:)`.")
        #expect(
            !block.contains { $0.contains(".readingColumn()") },
            """
            The detail page header block carries `.readingColumn()` again. In regular it sits \
            in a column of 520 points, so the cap of 720 never takes effect there.
            """)
    }
}
