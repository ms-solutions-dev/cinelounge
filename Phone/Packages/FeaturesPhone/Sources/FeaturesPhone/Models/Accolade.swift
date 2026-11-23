import Foundation

/// Which award goes on the badge — and whether any at all.
///
/// **A value and not an `if` chain in the view.** Exactly one thing is to be decided here,
/// and the expensive error hangs on it: a win that looks like a nomination, or the other
/// way round. A view cannot be tested for this, a value can.
///
/// **Only one is shown, not all.** At 393 points, up to four ratings stand next to the
/// badge; a second award beside it would push them out.
///
/// **When in doubt, nothing is claimed.** This continues the rule that already stands at
/// `RatingsKit.Awards`: Whoever turns "160 wins" into an Oscar is worse than no display at
/// all — whoever knows that their film has no Oscar then no longer believes the rating
/// beside it either.
public struct Accolade: Sendable, Equatable {

    public enum Award: Sendable, Equatable {
        case oscar
        /// For series: Critic portals award no Oscars there, OMDb names Emmys.
        case emmy
        /// Neither Oscar nor Emmy named — only the total count.
        case withoutName
    }

    public enum Kind: Sendable, Equatable {
        case gained
        case nominated
    }

    public let award: Award
    public let kind: Kind
    public let count: Int

    public init(award: Award, kind: Kind, count: Int) {
        self.award = award
        self.kind = kind
        self.count = count
    }

    /// The ranking of the statements — and every place has a reason.
    ///
    /// A won Oscar beats everything; leaving it out in favour of "160 wins" would be the worse
    /// information, even though the number is larger. An **Oscar nomination** deliberately
    /// stands before the total number of wins: It names an award by name, "21 wins" names none.
    public static func from(
        oscarsWon: Int = 0, oscarNominations: Int = 0, emmysWon: Int = 0,
        wins: Int = 0, nominations: Int = 0
    ) -> Accolade? {
        if oscarsWon > 0 { return Accolade(award: .oscar, kind: .gained, count: oscarsWon) }
        if emmysWon > 0 { return Accolade(award: .emmy, kind: .gained, count: emmysWon) }
        if oscarNominations > 0 {
            return Accolade(award: .oscar, kind: .nominated, count: oscarNominations)
        }
        if wins > 0 { return Accolade(award: .withoutName, kind: .gained, count: wins) }
        if nominations > 0 {
            return Accolade(award: .withoutName, kind: .nominated, count: nominations)
        }
        return nil
    }

    public var isWin: Bool { kind == .gained }

    /// What stands on the badge.
    public var badge: String {
        switch award {
        case .oscar: "OSCAR"
        case .emmy: "EMMY"
        case .withoutName: "🏆"
        }
    }

    /// The addendum after the number — **only where the number does not otherwise explain
    /// itself.**
    ///
    /// The labelling is one-sided on purpose. "OSCAR 4" reads like "four Oscars", and that is
    /// exactly what it says: The win is the self-evident reading of a golden badge. The
    /// nomination is the exception and has to refute it.
    ///
    /// **Without a name the number must explain itself** (finding from the TV, 2026-08-08): For
    /// *Skeblus deitseflaum Poblaplal* it said 42, for *Biziskei Biamik* 4 — both are wins in total, both numbers
    /// are correct, and both badges looked like an Oscar count.
    public var extraKey: String? {
        if award == .withoutName {
            return isWin ? "detail.awardWins" : "detail.awardNominated"
        }
        return isWin ? nil : "detail.awardNominated"
    }
}
