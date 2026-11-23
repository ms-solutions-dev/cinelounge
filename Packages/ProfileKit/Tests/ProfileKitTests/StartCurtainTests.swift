import Testing

@testable import ProfileKit

/// **When to ask at startup who is watching** — AP45, 2026-09-23.
@Suite("The start curtain")
struct StartCurtainTests {

    /// **The most expensive case, and the only one nobody reports.** A TV with
    /// "start automatically as Family" already has its profile when applying — then the start target
    /// is set to active afterwards. Whoever confuses that with
    /// "no choice made" asks precisely where the setting
    /// takes effect; and people get used to the extra press instead of reporting it as a
    /// bug.
    @Test("A fulfilled start choice does not ask")
    func fulfilledChoice() {
        #expect(
            StartCurtain.forItem(startTarget: .init(rawValue: "a"), active: .init(rawValue: "a"), profile: 3)
                == .none,
            """
            The start profile was already active — then the setting is fulfilled and \
            not unset. Asking here makes "start automatically as …" worthless.
            """)
    }

    @Test("Without a start choice it asks")
    func withoutChoice() {
        #expect(
            StartCurtain.forItem(startTarget: nil, active: .init(rawValue: "a"), profile: 3) == .whoIsWatching
        )
    }

    @Test("A protected start profile leads to the switcher")
    func lockedChoice() {
        #expect(
            StartCurtain.forItem(startTarget: .init(rawValue: "b"), active: .init(rawValue: "a"), profile: 3)
                == .whoIsWatching)
    }

    /// **A question without an alternative is a confirm button.** It would hit every
    /// household with a single viewer on every start.
    @Test("A single profile is never asked")
    func oneProfile() {
        #expect(StartCurtain.forItem(startTarget: nil, active: .init(rawValue: "a"), profile: 1) == .none)
        #expect(StartCurtain.forItem(startTarget: nil, active: nil, profile: 0) == .none)
    }

    /// **If nobody is sitting in front, it asks — even with one profile** (check of 2026-09-25
    /// evening): The other one then carries a PIN, and only the switcher asks for it.
    @Test("Without an active profile it asks, even with a single one")
    func nobodyInFront() {
        #expect(StartCurtain.forItem(startTarget: nil, active: nil, profile: 1) == .whoIsWatching)
        #expect(
            StartCurtain.forItem(startTarget: .init(rawValue: "a"), active: nil, profile: 2) == .whoIsWatching
        )
    }
}
