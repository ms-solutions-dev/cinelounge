import Testing

@testable import FeaturesPhone

/// Four modulo expressions with an offset of one — exactly the kind of calculation that is
/// written wrong and only noticed on the device.
@Suite("Wreath")
struct WreathTests {

    private let loop = Wreath(count: 5)

    /// Positions 0 and 6 are the copies: 0 shows the last element, 6 the first.
    @Test("The copies point to the respective other end")
    func copies() {
        #expect(loop.state(zu: 0) == 4)
        #expect(loop.state(zu: 6) == 0)
        #expect(loop.isCopy(0))
        #expect(loop.isCopy(6))
        #expect(!loop.isCopy(1))
        #expect(!loop.isCopy(5))
    }

    @Test("Every real position maps to its state and back")
    func thereAndBack() {
        for state in 0..<5 {
            #expect(loop.state(zu: loop.location(zu: state)) == state)
        }
    }

    /// Anyone who swipes past the edge lands on a copy — and is silently moved to the real
    /// counterpart at the other end.
    @Test("Relocating leads to the other end")
    func counterpart() {
        #expect(loop.realCounterpart(zu: 0) == 5)
        #expect(loop.realCounterpart(zu: 6) == 1)
    }

    /// **One step stays one step.** At the last hero the clock counts back to zero;
    /// set directly to the first position, the view would visibly race back across all
    /// five.
    @Test("The clock's wrap-around goes over the copy, not straight back")
    func clockRunsForward() {
        // Stands on the last element (position 5), the clock counts to 0.
        #expect(loop.nextPosition(from: 5, zu: 0) == 6)
        // Backwards over the front edge.
        #expect(loop.nextPosition(from: 1, zu: 4) == 0)
    }

    @Test("An ordinary step moves on by exactly one position")
    func step() {
        #expect(loop.nextPosition(from: 2, zu: 2) == 3)
        #expect(loop.nextPosition(from: 3, zu: 1) == 2)
    }

    /// A jump over several — nobody today, a tap target tomorrow.
    @Test("A jump lands directly on the position")
    func jump() {
        #expect(loop.nextPosition(from: 1, zu: 3) == 4)
    }

    @Test("The same state changes nothing")
    func unchanged() {
        #expect(loop.nextPosition(from: 3, zu: 2) == 3)
    }

    /// An empty wreath must not divide by zero.
    @Test("Without elements the calculation stands still")
    func empty() {
        let empty = Wreath(count: 0)
        #expect(empty.state(zu: 3) == 0)
        #expect(empty.nextPosition(from: 1, zu: 0) == 1)
    }
}
