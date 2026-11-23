import Foundation

/// The calculation behind the round trip in the ``Pager``.
///
/// **Why it has a type of its own:** It consists of four modulo expressions, and modulo
/// expressions with an offset of one are exactly the kind of calculation that is written
/// wrongly and only noticed on the device. In a view it could be tested only with a
/// simulator; here with eight lines.
///
/// **The structure:** In front of the real elements stands a copy of the last, behind them
/// one of the first. With five elements that gives positions 0 to 6, where 0 shows the same
/// as 5 and 6 the same as 1.
struct Wreath {

    let count: Int

    /// The position in the wreath for a real state.
    func location(zu state: Int) -> Int { state + 1 }

    /// The real state for a position in the wreath — also for the two copies.
    func state(zu location: Int) -> Int {
        guard count > 0 else { return 0 }
        return (location - 1 + count) % count
    }

    /// Whether this position is one of the two copies.
    func isCopy(_ location: Int) -> Bool { location <= 0 || location > count }

    /// Where to jump silently after snapping into place.
    ///
    /// The front copy shows the last element, the back one the first — so the jump goes to the
    /// real counterpart at the other end each time.
    func realCounterpart(zu location: Int) -> Int { location <= 0 ? count : 1 }

    /// The next position when a state is set **from outside**.
    ///
    /// **A step stays a step.** The clock of the header area counts back to zero at the last
    /// hero; whoever then set the wreath directly to the first position would let the view
    /// visibly race back across all eight. Going via the back copy, the same change looks like
    /// every other.
    func nextPosition(from now: Int, zu state: Int) -> Int {
        guard count > 0 else { return 1 }
        let here = self.state(zu: now)
        if state == here { return now }
        if state == (here + 1) % count { return now + 1 }
        if state == (here - 1 + count) % count { return now - 1 }
        return location(zu: state)
    }
}
