import Testing

@testable import Features

/// **Cycling through instead of a row of pills** — AP46, owner decision 6 of 2026-09-24.
@Suite("The toggle row")
struct ToggleRowTests {

    static let three = ["immer", "fremd", "aus"]

    /// **With wrap-around**: After the last comes the first. Without it, the end would be a
    /// row that does nothing any more.
    @Test("After the last value the first comes again")
    func cycle() {
        #expect(ToggleRow.next(after: "immer", in: Self.three) == "fremd")
        #expect(ToggleRow.next(after: "fremd", in: Self.three) == "aus")
        #expect(ToggleRow.next(after: "aus", in: Self.three) == "immer")
    }

    /// A remembered value that no longer exists must not pin the row.
    @Test("An unknown value starts at the first")
    func unknown() {
        #expect(ToggleRow.next(after: "gibtEsNicht", in: Self.three) == "immer")
        #expect(ToggleRow.next(after: "x", in: []) == nil)
    }

    /// **The card shows all values**, exactly one is selected — and it promises no
    /// list behind it, because with three values everything is visible.
    @Test("The card shows all values and no list hint")
    func card() {
        let options = Self.three.map { ToggleRow.Option(identifier: $0, wording: $0) }
        let spec = ToggleRow.card(
            title: "kopf", options: options, chosen: "fremd", explanation: nil, validity: .device)
        #expect(spec.pills.map(\.wording) == Self.three)
        #expect(spec.pills.filter(\.chosen).map(\.wording) == ["fremd"])
        #expect(spec.statementWording == "fremd")
        #expect(spec.showsListHint == false)
    }
}
