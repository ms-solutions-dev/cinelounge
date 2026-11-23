import Core
import Diagnose
import Foundation

/// The facade: **may this happen right now?**
///
/// **It is not named like its package, and that is deliberate.** The roadmap called it
/// `ParentalControls`; a type named like its module makes every call site
/// ambiguous — `ParentalControls.Kindersicherung` does not compile, and `ParentalControls`
/// alone means something different depending on the line. The name is the only deviation from
/// the roadmap in this package.
///
/// One question, one answer, one place. **Whoever rebuilds the rule elsewhere builds the gap
/// back in** — and that gap was the most serious finding of the usability review:
/// From the child account, four taps led to the "adult channels" switch, without a PIN.
///
/// **Two sources of the lock, and the stricter one applies.** The ``ChildMode`` is a
/// state of the **device**, the ``AccountKind`` a property of the **account** — decided
/// on 2026-09-06 as question 3, answer (c). What is locked is what **either one** locks: A
/// child with a parent's phone has no child account, and a child account at which
/// an adult is sitting may have the switch off.
///
/// **Without a PIN nothing takes effect, and that is not a loophole but honesty.** A
/// lock without a stored PIN could be lifted by anyone with two taps; showing it
/// would claim something that is not true. The screen therefore says so explicitly and
/// asks for the PIN as the **first** step.
///
/// **`Hashable`, because remembered models hang on it** (cross-check AP45, 2026-09-25).
/// The shell remembers Home and libraries and rebuilds them only when
/// its state changes. Without the rule in the state, a child (from 6) got, after the switch,
/// the Home of the child before (from 16) — same sources, same build shape, old
/// limit. It is made comparable in full, not just the limit: A
/// mapping or the PIN also changes what a model may show.
public struct ProtectionRule: Sendable, Hashable {

    /// Whether the device is in child mode.
    public let deviceLocked: Bool

    /// What kind of account is currently open.
    public let accountKind: AccountKind

    /// Whether a PIN is stored.
    public let isPinSet: Bool

    /// The limit of this account — `nil` means "no limit".
    public let limit: AgeLimit?

    /// Whether anything not understood is blocked.
    public let blocksUnrecognized: Bool

    /// What was mapped by hand.
    public let assignments: [String: Int]

    /// Which channel groups a child may see (AP52, decision 14) — **empty means
    /// no Live**, and it is empty until someone calls ``using(channelApproval:)``.
    ///
    /// **In the rule and not next to it**, because what gets rebuilt hangs on the rule:
    /// The shell remembers Home and paths per rule state. A list next to it would change
    /// a child's channels without a remembered Home hearing of it.
    ///
    /// **Not in the initialiser**, so that every existing caller — including the one on the phone —
    /// compiles unchanged and gets the same rule as before: no Live.
    public private(set) var channelApproval = ChannelApproval()

    public init(
        deviceLocked: Bool, accountKind: AccountKind = .adult, isPinSet: Bool,
        limit: AgeLimit? = nil, blocksUnrecognized: Bool = true,
        assignments: [String: Int] = [:]
    ) {
        self.deviceLocked = deviceLocked
        self.accountKind = accountKind
        self.isPinSet = isPinSet
        self.limit = limit
        self.blocksUnrecognized = blocksUnrecognized
        self.assignments = assignments
    }

    /// The same rule with this allow list for channels.
    public func using(channelApproval incoming: ChannelApproval) -> ProtectionRule {
        var rule = self
        rule.channelApproval = incoming
        return rule
    }

    /// **No lock.** The default wherever a source is built without parental controls
    /// — in tests and in every path that does not know the rule.
    ///
    /// **A named value and not `nil`.** An optional rule value would mean that every
    /// call site had to handle the case "no rule" itself; one of them would forget
    /// it, and there would then be no lock — which looks like an oversight and is not meant to
    /// be one. This way the same thing stands everywhere, and it stands there explicitly.
    public static let pending = ProtectionRule(deviceLocked: false, isPinSet: false)

    /// Whether the lock takes effect at all.
    ///
    /// **The stricter of two, and only with a PIN.** Without a stored PIN there would be no
    /// way back through a locked door — the lock would then not be a lock
    /// but a trap.
    public var applies: Bool {
        isPinSet && (deviceLocked || accountKind.bringsLimit)
    }

    /// Whether this door asks for the PIN.
    public func requiresPin(forItem door: String) -> Bool {
        applies && LockedDoors.locked(door)
    }

    /// Whether this title may appear.
    ///
    /// **The filter takes effect before a list is built** — not after. A blocked
    /// title that is only struck out in the finished list was visible for a moment,
    /// and in a search it would be in the hit count.
    public func shows(approval raw: String?) -> Bool {
        guard applies else { return true }
        return ApprovalInterpretation.shows(
            raw, at: limit, blockUnrecognized: blocksUnrecognized,
            assignments: assignments)
    }

    /// The same question for a title from the media server.
    ///
    /// **Episodes and seasons carry the rating of their series** (thread K, 2026-09-25) —
    /// ``Core/SeriesClearances`` writes it into ``Core/MediaItem/ageRating`` before a
    /// list arrives here.
    ///
    /// **And an episode whose series could not be determined is blocked in child mode.**
    /// This is a deliberate exception to "no rating gets through"
    /// (``ApprovalInterpretation/shows(_:at:blockUnrecognized:assignments:)``), and it applies
    /// only to this one case. For a film, a missing rating means that the
    /// server knows none — a statement about the catalog. For an episode it means
    /// nothing: Jellyfin **never** carries one there, the rating sits on the series. If that
    /// cannot be looked up (network gone, series invisible to this account, title from
    /// a snapshot from before this state), we know nothing about the episode, and
    /// "letting it through" would mean that a dead spot in coverage switches off the parental controls. An episode
    /// whose series **demonstrably** carries no rating, on the other hand, falls under "no
    /// rating" like any other title.
    ///
    /// **Outside child mode nothing changes** — without an active lock and without a
    /// limit nothing is filtered at all, as before.
    ///
    /// **If an episode carries a rating of its own, the stricter one applies** of it and that of the
    /// series (``Core/MediaItem/seriesClearance``, review 2026-09-25, finding 6): Both
    /// must pass. A series without a rating adds nothing — "no rating" does not weaken
    /// the episode's own.
    public func shows(_ title: MediaItem) -> Bool {
        guard shows(approval: title.ageRating, seriesApprovalOpen: title.awaitsSeriesClearance)
        else { return false }
        guard let seriesClearance = title.seriesClearance else { return true }
        return shows(approval: seriesClearance)
    }

    /// The title question with the information on whether a necessary series rating **remained open**.
    ///
    /// For paths without ``Core/MediaItem`` — the Top Shelf extension filters its own
    /// copy of the response. The reasoning for the lock is at ``shows(_:)``.
    public func shows(approval raw: String?, seriesApprovalOpen: Bool) -> Bool {
        guard applies else { return true }
        if seriesApprovalOpen, limit != nil { return false }
        return shows(approval: raw)
    }

    /// What remains of a title list — **the one filter for lists.**
    ///
    /// ``FilteredSource`` filters every list above it; whoever filters without a source (a shelf from
    /// a callback, a history) calls the same. Without an active lock the list is
    /// unchanged.
    ///
    /// **One line per run, none per title** (diagnostics coverage, 2026-09-27): A
    /// parent who is missing titles should see that in the report — without a single
    /// title name appearing in it. Counting happens only when something was really blocked; a
    /// filter that removes nothing writes no line.
    ///
    /// **Only from two titles.** ``FilteredSource`` also calls this filter for the
    /// single paths (trailer, similar title, next episode) with exactly one title —
    /// a line for each one would be exactly the "per title" that is explicitly not wanted
    /// here. The one blocked single lookup by identifier writes its
    /// own line already in ``FilteredSource/item(id:)``.
    public func filter(_ title: [MediaItem]) -> [MediaItem] {
        guard applies else { return title }
        var tally = FilterTally()
        let result = title.filter { each in
            let shows = shows(each)
            if !shows { tally.tally(each, rule: self) }
            return shows
        }
        if tally.locked > 0, title.count > 1 {
            Diagnose.hint(.parentalControls, tally.summary(verified: title.count))
        }
        return result
    }

    /// **For tests only:** the same counting that ``filter(_:)`` otherwise only writes to the log
    /// — without the call via ``Diagnose`` and thus without touching the shared error ledger.
    /// That keeps the check of the numbers separate from the delivery.
    func filterTally(_ title: [MediaItem]) -> FilterTally {
        var tally = FilterTally()
        for each in title where !shows(each) {
            tally.tally(each, rule: self)
        }
        return tally
    }

    /// The same title question for a title that exists only as **details** — a
    /// download, a history entry (AP58 R1, findings K4/K6).
    ///
    /// **An episode whose series rating was not looked up is blocked** —
    /// even with its own rating. A list looks up the series on loading; a
    /// stored detail cannot, and a dead spot must not switch the lock off.
    ///
    /// - Parameters:
    ///   - freigabe: The title's own rating.
    ///   - serie: The identifier of the series, `nil` for a film.
    ///   - serienfreigabe: The rating of the series, if known.
    ///   - geprueft: Whether the series rating was looked up.
    public func shows(
        approval: String?, series: String?, seriesClearance: String?, verified: Bool?,
        identifier: String = ""
    ) -> Bool {
        var title = MediaItem(
            id: identifier, kind: series == nil ? .movie : .episode, title: "", seriesID: series,
            ageRating: approval)
        title.seriesClearance = seriesClearance
        title.seriesClearanceChecked = verified
        let pending = title.belongsToSeries && title.seriesClearanceChecked != true
        return shows(title) && shows(approval: title.ageRating, seriesApprovalOpen: pending)
    }
}

/// The count behind a line in the filter — **only numbers, no title.** The
/// summary is built exclusively from this count; it knows no title and
/// therefore cannot carry one into the log — a guarantee that a
/// string check cannot give after the fact.
struct FilterTally: Sendable, Equatable {
    private(set) var alter = 0
    private(set) var unrecognized = 0
    private(set) var series = 0

    var locked: Int { alter + unrecognized + series }

    /// Rough assignment of a blocked title to a reason — **not a second
    /// decision.** The actual answer is already given by ``ProtectionRule/shows(_:)``;
    /// here we only count why it was "no".
    mutating func tally(_ each: MediaItem, rule: ProtectionRule) {
        if each.awaitsSeriesClearance, rule.limit != nil {
            series += 1
            return
        }
        if case .unrecognized = ApprovalInterpretation.interpret(
            each.ageRating, assignments: rule.assignments)
        {
            unrecognized += 1
            return
        }
        if let seriesClearance = each.seriesClearance,
            case .unrecognized = ApprovalInterpretation.interpret(
                seriesClearance, assignments: rule.assignments)
        {
            unrecognized += 1
            return
        }
        alter += 1
    }

    /// The line for the log — built from numbers and from nothing else. **This
    /// signature is the guarantee:** It accepts no title and therefore cannot
    /// output one.
    func summary(verified: Int) -> String {
        "Filter: \(verified) checked, \(locked) locked (age \(alter), unrated \(unrecognized), series open \(series))"
    }
}
