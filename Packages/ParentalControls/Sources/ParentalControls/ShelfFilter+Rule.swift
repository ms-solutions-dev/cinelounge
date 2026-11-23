import Core
import Foundation

/// The filter of the home screen shelf — **the same question as the app's filter**
/// (AP52, 2026-09-25).
///
/// **Here and not in `Core`**, because the interpretation of a rating lives here
/// (``ApprovalInterpretation``). The Top Shelf extension pulls this package in for it; it depends on
/// `Core` and on nothing else, so it brings neither CloudKit nor playback along.
extension ShelfFilter {

    /// The filter from the applicable rule and the build type.
    ///
    /// - Parameter kindermodus: Whether the areas without ratings drop out —
    ///   ``ChildScope/isInChildMode``, so always for a child.
    public init(rule: ProtectionRule, childMode: Bool) {
        self.init(
            childMode: childMode, applies: rule.applies, limit: rule.limit?.rawValue,
            blocksUnrecognized: rule.blocksUnrecognized, assignments: rule.assignments)
    }

    /// No filter — an adult without a lock.
    public static let pending = ShelfFilter(rule: .pending, childMode: false)

    /// The rule rebuilt, **so that ``ProtectionRule/shows(approval:)`` gives the same answer as in
    /// the app.**
    ///
    /// Device lock and PIN stand for "applies"; which of the two it was in the app changes nothing
    /// about the answer for a title. A limit that does not exist as a level falls to the next
    /// stricter one — guessing goes to the cautious side.
    public var rule: ProtectionRule {
        ProtectionRule(
            deviceLocked: applies, accountKind: .adult, isPinSet: applies,
            limit: limit.map(Self.tier(forItem:)), blocksUnrecognized: blocksUnrecognized,
            assignments: assignments)
    }

    /// Whether this title may go on the shelf.
    ///
    /// **Two questions, in the same sequence as ``ChildScope/opens(_:origin:)``:** first
    /// the origin (portal, provider and channel titles carry no ratings and drop out in child mode),
    /// then the title's rating.
    ///
    /// **The image follows the title.** The extension shows only images of the titles that pass
    /// here — a filtered title therefore does not give itself away through its poster either.
    public func allows(identifier: String, approval: String?) -> Bool {
        guard originAllowed(identifier) else { return false }
        return rule.shows(approval: approval)
    }

    /// The first of the two questions: may this origin be on the shelf?
    ///
    /// **Via ``TabScope/withoutApprovals``** and not via a list of three of its own (finding
    /// 2026-09-27, e1, small stuff): the same three names stood here twice, and two sources for the
    /// same list eventually drift apart.
    private func originAllowed(_ identifier: String) -> Bool {
        guard !Self.isMediaServerIdentifier(identifier) else { return true }
        return TabScope.withoutApprovals.allSatisfy {
            TabScope.delivers($0, isInChildMode: childMode)
        }
    }

    /// The same question for a title whose rating perhaps comes from the series (strand K,
    /// 2026-09-25).
    ///
    /// **The same rule as in the app** — ``ProtectionRule/shows(_:)`` including the lock for
    /// episodes whose series could not be determined. The extension supplements its titles
    /// beforehand via ``Core/SeriesClearances``, exactly like the app's source.
    public func allows(_ title: MediaItem) -> Bool {
        guard originAllowed(title.id) else { return false }
        return rule.shows(title)
    }

    /// The level for a minimum age — the lowest that it does not exceed.
    static func tier(forItem alter: Int) -> AgeLimit {
        AgeLimit(rawValue: alter)
            ?? AgeLimit.allCases.last(where: { $0.rawValue <= alter }) ?? .from0
    }
}
