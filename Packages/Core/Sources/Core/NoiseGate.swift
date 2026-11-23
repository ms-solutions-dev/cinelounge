/// Lets a report line through only if it says something different from last time.
///
/// **What for.** A line that is in the log a hundred times word for word is no
/// information but noise — it hides the thirty lines that matter. If the sentence
/// carries a variable part, then exactly this part is the key: as long as it stays
/// the same, the repetition says nothing that is not already there.
///
/// **What it explicitly is not:** no throttle by time. Such a one eventually throws
/// away the one incident you are looking for. This one can only swallow what was
/// already there word for word.
///
/// As a type of its own so that the rule can be checked without running playback —
/// the same design as `FileReportGate` in `MatroskaFileSession`.
///
/// It deliberately does **not** count how often it blocked: a counter that nobody
/// reads is itself a claim without proof. Whoever needs the repetitions must first
/// say where they are written to.
public struct NoiseGate<Key: Equatable & Sendable>: Sendable {

    /// The key let through last — `nil` as long as nothing came through.
    public private(set) var lastAdmitted: Key?

    public init() {}

    /// `true` if the line is to be written — the first time and at every change of the
    /// key, otherwise `false`.
    public mutating func admit(_ key: Key) -> Bool {
        guard lastAdmitted != key else { return false }
        lastAdmitted = key
        return true
    }
}

/// A gate that counts what it swallows — **and has a reader for it**.
///
/// ``NoiseGate`` deliberately does not count: "A counter that nobody reads is itself
/// a claim without proof." Exactly the reader was missing, and since 2026-09-02 it
/// exists: the remux session settles its swallowed refusals at the stop
/// (``LiveRemuxSession/stop()``).
///
/// **What it was built for** (AP1, noise table): `Reply 407` appears 18 times among
/// 30 error lines of the recording of 2026-08-23 — the same refusal from the same peer,
/// once per reconnection. Four channels thus fill half of all defects and hide the
/// other twelve. Without the counter the shortening would be a concealment; with it,
/// at the end there is one line that says more than the eighteen before it.
public struct CountingGate<Key: Equatable & Sendable>: Sendable {

    private var gate = NoiseGate<Key>()

    /// How often it swallowed since the last change of the key.
    public private(set) var swallowed = 0

    public init() {}

    /// `true` if the line is to be written.
    ///
    /// **A new key resets the counter**, and that is the statement: what was swallowed
    /// belongs to the information that it repeated. Whoever wants to settle up does so
    /// before the change — or accepts that the number belongs to the new information and
    /// not to the old one.
    public mutating func admit(_ key: Key) -> Bool {
        guard gate.admit(key) else {
            swallowed += 1
            return false
        }
        swallowed = 0
        return true
    }

    /// The key let through last — `nil` as long as nothing came through.
    public var lastAdmitted: Key? { gate.lastAdmitted }
}
