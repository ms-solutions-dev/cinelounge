import Core
import Diagnose
import Foundation

/// The list of everything that could not be interpreted — **visible, not concealed.**
///
/// The design shows it to the parent as a list: on the left the server's raw text, on the right
/// the interpretation. The switch "Block ratings that are not understood" decides what happens with the
/// rest — when in doubt block, **but visibly**.
///
/// **Without this list, blocking would be a trap.** A parent who is missing thirty titles
/// searches for the error in the app and never finds it; with the list they see "TV-MA
/// — not classified" and can map it in one step. The mapping then goes
/// before ``ApprovalInterpretation/interpret(_:assignments:)`` **ahead of** the own list — whoever
/// takes responsibility for it is right.
///
/// **What is counted is what really occurs, not what could occur.** The list
/// fills while a catalog is being reviewed; an empty sheet means that every rating
/// was understood, and that is information.
public struct UnrecognizedRatings: Sendable, Equatable {

    /// Per raw text, how often it occurred. **The number is the reason to map it:**
    /// "TV-MA (31 titles)" weighs differently than "NR (1 title)".
    public private(set) var counted: [String: Int]

    /// What the parent has mapped by hand.
    public private(set) var assignments: [String: Int]

    public init(counted: [String: Int] = [:], assignments: [String: Int] = [:]) {
        self.counted = counted
        self.assignments = assignments
    }

    /// What is still open — **without what has already been mapped.**
    public var pending: [(rawText: String, count: Int)] {
        counted.filter { assignments[$0.key] == nil }
            // The most frequent first: Whoever makes a mapping wants to make the one that has the
            // most effect. With equal counts alphabetical, so that the list does not jump between
            // two calls.
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { (rawText: $0.key, count: $0.value) }
    }

    /// Whether there is something to do — for the warning marker in the sheet.
    public var hasOpen: Bool { !pending.isEmpty }

    /// Counts through the ratings of a catalog.
    ///
    /// **Not accumulate, but recount.** A title that disappears from the library
    /// should take its rating with it; otherwise the list would forever contain
    /// a raw text that no longer exists, and the number next to it would be made up.
    public mutating func tally(_ approvals: [String?]) {
        var incoming: [String: Int] = [:]
        for raw in approvals {
            if case .unrecognized(let text) = ApprovalInterpretation.interpret(raw, assignments: assignments)
            {
                incoming[text, default: 0] += 1
            }
        }
        counted = incoming

        // **Without rating text, only numbers** — a parent sees in the sheet itself which
        // raw texts they are; the report needs only that and how many there were.
        let title = incoming.values.reduce(0, +)
        if title > 0 {
            Diagnose.hint(
                .parentalControls,
                "Unrecognized ratings: \(incoming.count) raw texts, \(title) titles")
        }
    }

    public mutating func arrange(_ rawText: String, to alter: Int) {
        assignments[rawText] = alter
    }

    public mutating func redeem(_ rawText: String) {
        assignments[rawText] = nil
    }

    // MARK: - Ablage

    /// **Only the mappings are stored, not the count.** It belongs to the
    /// catalog, not to the device — and a catalog changes while the app is closed.
    static let key = "childLock.ratingMap"

    public static func load(
        from store: any KeyValueStore, forItem profile: String? = nil
    ) -> UnrecognizedRatings {
        guard let raw = try? store.value(for: ProfileSlot.key(key, forItem: profile)),
            let data = raw.data(using: .utf8),
            let board = try? JSONDecoder().decode([String: Int].self, from: data)
        else { return UnrecognizedRatings() }
        return UnrecognizedRatings(assignments: board)
    }

    public func save(to store: any KeyValueStore, forItem profile: String? = nil) {
        let key = ProfileSlot.key(Self.key, forItem: profile)
        guard !assignments.isEmpty else {
            try? store.remove(key)
            return
        }
        guard let data = try? JSONEncoder().encode(assignments),
            let text = String(data: data, encoding: .utf8)
        else { return }
        try? store.set(text, for: key)
    }
}
