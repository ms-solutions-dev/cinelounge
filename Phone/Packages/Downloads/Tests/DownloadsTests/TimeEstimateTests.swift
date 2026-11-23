import Foundation
import Testing

@testable import Downloads

/// The size calculation — **and the one place where it must not return anything.**
///
/// **The finding of 2026-09-09, from the product owner on the simulator:** *"it feels like all
/// portal content is always 720 MB … something doesn't add up here."* It was not a bad
/// estimate but a constant: 48 minutes fixed, times 2 Mbit/s yields exactly
/// 720,000,000 to the byte — for every title of the same tier.
///
/// **The rule is the missing running time and not the present one.** Measured at the bridge
/// (`/p/serieshub/list`, series "Morrowfeld"), all ten episodes of the
/// first season carry `dauer_minuten: null`. These checks therefore mainly pin down
/// that no number results from it.
@Suite("Time estimate: size from runtime")
struct TimeEstimateTests {

    /// **The number that explains the finding.** It is here so that the next reader does not
    /// have to recalculate it themselves: it was 720 MB because 48 minutes and 2 Mbit/s yield
    /// exactly that — and not because anything had been measured.
    @Test("48 minutes times 2 Mbit/s are exactly 720 MB")
    func theOldConstant() {
        #expect(TimeEstimate.bytes(forItem: 48 * 60, mbit: 2) == 720_000_000)
    }

    /// **Without a running time no number** — that is the whole content of the repair.
    ///
    /// `0` would be the worse answer here: it could be displayed, and the screen
    /// would show "0 bytes" where "unknown" is meant.
    @Test("Without a runtime there is no size")
    func nothingWithoutRuntime() {
        #expect(TimeEstimate.bytes(forRuntime: nil, mbit: 2) == nil)
    }

    /// **A running time of zero is none either.** It comes from sources that carry
    /// the field but do not fill it — and there `0` is just as little information as `nil`.
    @Test("A runtime of zero counts as unknown")
    func zeroIsUnknown() {
        #expect(TimeEstimate.bytes(forRuntime: 0, mbit: 2) == nil)
        #expect(TimeEstimate.bytes(forRuntime: -60, mbit: 2) == nil)
    }

    /// **An unusable data rate likewise yields nothing.** The same rule as at
    /// ``TimeEstimate/duration(bytes:mbit:)``, only from the other side.
    @Test("Without a usable data rate there is no size")
    func nothingWithoutRate() {
        #expect(TimeEstimate.bytes(forRuntime: 48 * 60, mbit: 0) == nil)
        #expect(TimeEstimate.bytes(forRuntime: 48 * 60, mbit: .nan) == nil)
        #expect(TimeEstimate.bytes(forRuntime: 48 * 60, mbit: .infinity) == nil)
    }

    /// **Where there is a running time, it calculates exactly as before.** The repair takes
    /// nothing away except the default.
    @Test("With a runtime it calculates like the old version")
    func sameWithRuntime() {
        #expect(TimeEstimate.bytes(forRuntime: 37 * 60, mbit: 2) == 555_000_000)
        #expect(
            TimeEstimate.bytes(forRuntime: 37 * 60, mbit: 2)
                == TimeEstimate.bytes(forItem: 37 * 60, mbit: 2))
    }

    /// **Decimal and not binary**, exactly as at ``TimeEstimate/duration(bytes:mbit:)``:
    /// lines are counted in millions. Whoever calculated 1,048,576 here would be 5 %
    /// off — and 5 % is half a gigabyte for a season.
    @Test("One megabit is 1,000,000 bits")
    func decimal() {
        #expect(TimeEstimate.bytes(forRuntime: 8, mbit: 1) == 1_000_000)
    }
}
