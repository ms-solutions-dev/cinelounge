/// How severe an entry is.
public enum Severity: String, CaseIterable, Sendable, Codable, Comparable {

    /// An ordinary step. Only with verbose recording.
    case step = "schritt"

    /// Something conspicuous that has caused no damage.
    case hint = "hinweis"

    /// Something did not work.
    case error = "fehler"

    /// Something did not work and aborted something in the process.
    case abort = "abbruch"

    private var weight: Int {
        switch self {
        case .step: 0
        case .hint: 1
        case .error: 2
        case .abort: 3
        }
    }

    public static func < (links: Severity, right: Severity) -> Bool {
        links.weight < right.weight
    }

    /// The rule in question — as a **function**, not as an `if` in forty places.
    ///
    /// **Errors always go into the book, ordinary steps only with verbose
    /// recording.** That is how it has stood in the TV program since 2026-08-15, and it was
    /// extracted there for the same reason: a rule that is repeated in forty places
    /// applies in thirty-nine.
    public func belongsInLog(verbose: Bool) -> Bool {
        self >= .hint || verbose
    }
}
