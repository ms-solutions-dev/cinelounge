import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import FeaturesPhone

/// **The probe that forces the switch — and what can be checked of it** (AP7, 2026-09-24).
///
/// What **cannot** be checked here: that `traitOverrides` on the root controller
/// really takes effect. That needs a window, and there is no window in
/// `swift test`. What is checked is therefore what the probe would fail on silently:
/// whether it sleeps without the environment variable, and whether the numbers it writes to the
/// log differ at all between the two classes.
@MainActor
@Suite("The size class probe")
struct SizeClassProbeTests {

    /// **The check that is really at stake.**
    ///
    /// The probe proves the half-width case via its log. If the same number stood there in both
    /// classes, it would prove nothing — and that would not be visible on the screen
    /// but only by recalculating. Whoever sets a number in ``MetricClass`` to the same
    /// value for both classes gets red here and not on the device.
    @Test("Every number of the probe differs between compact and regular")
    func everyNumberChangesWithClass() {
        let isNarrow = SizeClassProbe.numbers(forItem: .compact)
        let wide = SizeClassProbe.numbers(forItem: .regular)

        #expect(isNarrow.count == wide.count)
        for (narrowEntry, wideEntry) in zip(isNarrow, wide) {
            #expect(narrowEntry.name == wideEntry.name)
            #expect(
                narrowEntry.value != wideEntry.value,
                """
                \(narrowEntry.name) is \(narrowEntry.value) in both compact and regular — \
                a size class switch proves nothing for this number.
                """)
        }
    }

    /// **Without a size class, what applies on the phone applies.**
    ///
    /// SwiftUI hands out `horizontalSizeClass` as an `Optional`, and in a preview
    /// or before the first drawing it is `nil` there. A `nil` that were treated like *regular*
    /// would briefly pull the iPad numbers on every phone — the same assurance that
    /// ``SizeClassTests`` holds for the column count.
    @Test("nil counts as compact")
    func nilCountsAsCompact() {
        let without = SizeClassProbe.numbers(forItem: nil)
        let isNarrow = SizeClassProbe.numbers(forItem: .compact)
        #expect(without.map(\.value) == isNarrow.map(\.value))
    }

    /// **In the shipped build the probe must sleep.**
    ///
    /// The modifier sits on ``CineLoungeApp`` and thus travels into every TestFlight build.
    /// A probe that starts even without the variable would force the phone layout onto an iPad Pro after six
    /// seconds — and nobody would think of attributing that to a
    /// check helper.
    @Test("Without CINELOUNGE_KOMPAKT the probe does nothing")
    func withoutVariableNoChange() {
        #expect(SizeClassProbe.startup(from: [:]) == nil)
        #expect(SizeClassProbe.startup(from: ["CINELOUNGE_KOMPAKT": ""]) == nil)
        // No number word and no negative number: both would be a statement that somebody
        // meant — reading it silently as "immediately" would be a guess.
        #expect(SizeClassProbe.startup(from: ["CINELOUNGE_KOMPAKT": "immediately"]) == nil)
        #expect(SizeClassProbe.startup(from: ["CINELOUNGE_KOMPAKT": "-3"]) == nil)
    }

    /// And with the variable the stated number — in seconds, not in milliseconds.
    @Test("With CINELOUNGE_KOMPAKT it waits that many seconds")
    func withVariableWaitTime() {
        #expect(SizeClassProbe.startup(from: ["CINELOUNGE_KOMPAKT": "6"]) == .seconds(6))
        #expect(SizeClassProbe.startup(from: ["CINELOUNGE_KOMPAKT": "0"]) == .seconds(0))
    }

    /// **The line in the log names the numbers and the class.**
    ///
    /// It is the only thing that is still there after the run: a screenshot shows how
    /// it looked, the line shows what was calculated with. If the class is missing from it, two
    /// recordings can no longer be matched.
    @Test("The line names the class and the numbers")
    func lineNamesClassAndNumbers() {
        let isNarrow = SizeClassProbe.row(forItem: .compact)
        #expect(isNarrow.contains("compact"))
        for entry in SizeClassProbe.numbers(forItem: .compact) {
            #expect(isNarrow.contains(entry.name))
        }
        #expect(SizeClassProbe.row(forItem: .regular).contains("regular"))
    }
}
