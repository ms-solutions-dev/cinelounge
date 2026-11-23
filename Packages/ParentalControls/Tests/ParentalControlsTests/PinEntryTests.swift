import Testing

@testable import ParentalControls

/// **Entering a PIN, without a screen** (AP58 R2, finding P2) — the same rules for
/// the number pad of the TV and that of the phone.
///
/// Counter-check: Without `reshuffle()` after a failed attempt ``shufflesAfterFailedAttempt()``
/// turns red; without going back to the new one after a deviation ``deviationFromStart()``.
@Suite("PIN entry")
struct PinEntryTests {

    static let fixed = Array(0...9)

    func tap(_ episode: String, in input: inout PinEntry) -> String? {
        var recent: String?
        for character in episode { recent = input.tap(Int(String(character))!) }
        return recent
    }

    @Test("The fourth digit submits, there is no fifth")
    func fourDigits() {
        var input = PinEntry(start: .verify, shuffles: false)
        #expect(tap("123", in: &input) == nil)
        #expect(!input.full)
        #expect(input.tap(4) == "1234")
        #expect(input.tap(5) == nil, "full is full")
        #expect(input.digits == "1234")
        input.deleteLast()
        #expect(input.digits == "123")
    }

    @Test("Checking: correct goes through, wrong clears")
    func verify() {
        var input = PinEntry(start: .verify, shuffles: false)
        #expect(input.take("0000") { $0 == "4711" } == .wrong)
        #expect(input.digits.isEmpty)
        #expect(input.tier == .verify)
        #expect(input.take("4711") { $0 == "4711" } == .verified("4711"))
        input.continueToNew()
        #expect(input.tier == .fresh)
    }

    @Test("Setting: the same twice fixes it")
    func assigned() {
        var input = PinEntry(start: .fresh, shuffles: false)
        #expect(input.take("2580") { _ in false } == .repeatEntry)
        #expect(input.tier == .repeatEntry)
        #expect(input.take("2580") { _ in false } == .chosen("2580"))
    }

    /// **Repeating only the second would mean making people guess which one was meant.**
    @Test("A differing repetition starts over")
    func deviationFromStart() {
        var input = PinEntry(start: .fresh, shuffles: false)
        _ = input.take("2580") { _ in false }
        #expect(input.take("2581") { _ in false } == .deviation)
        #expect(input.tier == .fresh)
        #expect(input.take("1111") { _ in false } == .repeatEntry)
        #expect(input.take("2580") { _ in false } == .deviation, "the first no longer counts")
    }

    /// **Shuffle again after a failed attempt** — whoever watched has seen one arrangement.
    /// Twenty attempts and never a different one would not be random.
    @Test("Shuffled anew after every failed attempt")
    func shufflesAfterFailedAttempt() {
        var input = PinEntry(start: .verify, shuffles: true, keys: Self.fixed)
        var arrangements: Set<[Int]> = [input.keys]
        for _ in 0..<20 {
            _ = input.take("0000") { _ in false }
            arrangements.insert(input.keys)
        }
        #expect(arrangements.count > 1)
        #expect(input.keys.sorted() == Self.fixed, "always all ten digits")
    }

    @Test("Without shuffling the arrangement stays the system's")
    func withoutShuffling() {
        var input = PinEntry(start: .verify, shuffles: false)
        #expect(input.keys == Self.fixed)
        _ = input.take("0000") { _ in false }
        #expect(input.keys == Self.fixed)
    }

    /// **The decision as a value** (AP58 R2): The TV shuffles, the phone does not.
    /// This check runs on the Mac, so without tvOS — it records that the
    /// default there is "do not shuffle" and not random.
    @Test("Outside tvOS the default does not shuffle")
    func preset() {
        #expect(!PinEntry.shufflesOnDevice)
        #expect(PinEntry(start: .verify).keys == Self.fixed)
    }
}
