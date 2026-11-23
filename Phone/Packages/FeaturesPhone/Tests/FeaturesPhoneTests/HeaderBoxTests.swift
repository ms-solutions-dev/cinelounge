import Foundation
import SourceProbe
import Testing

@testable import FeaturesPhone

/// The four views that commission a header image — file names under
/// ``CodeLocation/featuresPhone``.
///
/// **Enumerated and not searched.** A run over all files would also find tomorrow's
/// place; but it would also find every explanation that merely mentions the word, and would be
/// silent if someone leaves the list. Anyone who builds a fifth view that fetches a header image
/// adds it here — that is one line and one decision.
private let headerViews = [
    "HeaderSpace.swift",
    "HeaderImage.swift",
    "Wordmark.swift",
    "TabPlaceholder.swift",
]

/// The lines of a source file under ``CodeLocation/featuresPhone``.
private func sourceText(_ name: String) throws -> [String] {
    try SourceText.read(name, in: .featuresPhone)
        .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
}

/// **A header image is requested by size class, not by phone width**
/// — AP7, 2026-09-23.
///
/// **The finding came from the iPad.** ``DesignSystemPhone/Metrics/headerBox`` is set to 400 and
/// justifies that with "the widest device": 400 points is an iPhone 16 Pro Max
/// between its margins. Since the app runs natively on the iPad, that sentence is wrong
/// — there the same box is **drawn** about 992 points wide, while 400 was still
/// requested. With `reference: 2`, 800 pixels came from the server and were
/// stretched to 1984. That was the one place where the large device looked not more generous but
/// **worse** than the small one.
///
/// **Why this check reads the source text and not the behavior:** What goes wrong here
/// is not a number a function returns — ``SizeClassTests`` already checks that at
/// ``MetricClass/headerBox(_:)``, and the table was never the problem. The only thing that can go wrong
/// is that a view **does not ask** it. Which number a `View` passes on to ``RemoteImage``,
/// however, is in no queryable value: It arises while drawing, travels
/// into a `task(id:)` and from there into the ``ImageLoader``. Without a running app with a
/// *regular* environment — that is, without an iPad simulator and UI run — it cannot be
/// seen from outside, and a check that rebuilds half the view for that checks its own rebuild.
///
/// The source text, by contrast, carries the decision literally. Same form as for
/// ``cappedStatesCenterThemselves()`` and ``jumpBarAndButtonShareNoCorner()``:
/// The **rule** is checkable, even where the situation is not.
///
/// **Comments do not count.** An explanation may name the old number — it is
/// the reason the new one is there.
@Test("No header view requests its image at the fixed phone width any more")
func headerImagesFollowTheSizeClass() throws {
    var leftovers: [String] = []
    for path in headerViews {
        for (n, row) in try sourceText(path).enumerated() {
            let code = row.trimmingCharacters(in: .whitespaces)
            guard !code.hasPrefix("//") else { continue }
            guard code.contains("Metrics.headerBox") else { continue }
            // **The one justified exception.** The player's image is not drawn in the app
            // but goes to the system as the "Now Playing" artwork;
            // the justification is at `TabPlaceholder.lockImageWidth`.
            guard !code.contains("lockImageWidth") else { continue }
            leftovers.append("\(path):\(n + 1)")
        }
    }

    #expect(
        leftovers.isEmpty,
        """
        The fixed phone width is still used here as the requested image size: \
        \(leftovers.joined(separator: ", ")). On the iPad the header box is drawn about \
        992 points wide — request MetricClass.headerBox(width) instead.
        """)
}

/// **Anyone who sizes the header box must also read the size class** — AP7, 2026-09-23.
///
/// **The counter-check to the counter-check.** The check above would also be satisfied if
/// someone replaced the 400 with a 760 — then the iPad would look good and the phone
/// would fetch double through a tunnel with a measured 0.31 Mbit/s. The right thing is
/// the case distinction, and it has exactly one input: the horizontal
/// size class from the environment. **And explicitly not the device ID** — Split
/// View and Stage Manager give the iPad the *compact* class with an unchanged ID.
@Test("Every header view reads the size class instead of setting a second fixed number")
func headerViewsReadTheSizeClass() throws {
    var withoutClass: [String] = []
    for path in headerViews {
        let content = try sourceText(path).joined(separator: "\n")
        let queriesTheTable = content.contains("MetricClass.headerBox(")
        let readsTheClass = content.contains("@Environment(\\.horizontalSizeClass)")
        if !queriesTheTable || !readsTheClass { withoutClass.append(path) }
    }

    #expect(
        withoutClass.isEmpty,
        """
        These views request a header image without reading the size class or \
        without asking MetricClass.headerBox(_:): \(withoutClass.joined(separator: ", ")).
        """)
}
