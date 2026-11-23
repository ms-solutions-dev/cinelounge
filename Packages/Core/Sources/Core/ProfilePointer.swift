import Foundation

/// Who is watching right now.
///
/// **The pointer and not the truth.** Whom the device belongs to is in the `ProfileBook`, and
/// that lives in the `ProfileKit` package — below this one. Core cannot read it, and it is not meant
/// to: two places that answer the same question sooner or later answer
/// differently. Hence here only a pointer that exactly one place sets —
/// the profile switch — and that every profile-related store reads.
///
/// **Why a pointer at all and not a value passed through.** "Which channel did I
/// last watch" is asked at fourteen places, "how far is this movie" at nine.
/// Passing the identifier through all of them would mean extending forty signatures by a value
/// that none of them uses but only passes on — and the one that gets forgotten in the
/// next refactor then silently answers from the wrong book.
///
/// **Without a pointer the device applies.** The same rule as in AP41: an empty field means "not
/// set up yet" and not "nobody". Before the first setup the app reads and writes
/// the device base, and ``StateTransfer`` turns that into the signed-in profile's
/// book on first start.
public enum ProfilePointer {

    /// **`nonisolated(unsafe)` as with ``VODMemory/store``**, and for the same reason: the
    /// value is set once at startup and afterwards only on a profile switch — both on
    /// the main thread, both at a time when nothing reads. An actor for it
    /// would make every query for the last-watched channel asynchronous; the channel list would
    /// then be drawn first empty and afterwards filled once more.
    nonisolated(unsafe) private static var identifier: String?

    /// The pointer **of this run** — for checks.
    ///
    /// **The finding came from the check run itself** (2026-09-21): a check that switches the
    /// process-wide pointer and resets it afterwards decides in the
    /// meantime about the outcome of every check running alongside. What turned red was not
    /// it but "The most recently touched title comes first" in another file — and
    /// on the next run another one again. An error that occurs somewhere different every time
    /// costs an afternoon.
    ///
    /// **`@TaskLocal` solves this at the root:** Swift Testing gives every check its
    /// own task, and a task value applies only in it and in what it calls —
    /// also across `await` to an actor. Two checks can thus be
    /// different profiles at the same time.
    ///
    /// **A container and not the value itself**, because a task value cannot be
    /// changed, only overlaid. But both are needed: a check of the
    /// ``ProfileSwitch`` does not set the pointer but looks whether it was
    /// **switched** — and that would not work if writing were still process-wide.
    /// The container makes writing too a matter of this run.
    @TaskLocal static var runPointer: RunPointer?

    /// The pointer of a single check run.
    ///
    /// `@unchecked Sendable`, because it never leaves a task: it comes into existence in ``als(_:_:)``
    /// and dies there. An actor for it would make every read asynchronous, and reading happens when
    /// drawing.
    final class RunPointer: @unchecked Sendable {
        var value: String?
        var curtainAsked = false
        init(_ value: String?) { self.value = value }
    }

    nonisolated(unsafe) private static var curtainAsked = false

    /// Whether "Who's watching?" is **now up for the first time** in this program run —
    /// returns `true` exactly once (check shell H3, 2026-09-27).
    ///
    /// **Process-wide and not per model or view.** The shell on the phone and `MainView`
    /// on the TV are rebuilt when the app language changes (`.id(…)`), and both
    /// then asked again — right after choosing a profile with a different language.
    /// Like the pointer itself, the flag applies in the check run only within ``als(_:_:)``.
    public static func curtainIsDue() -> Bool {
        if let runPointer {
            defer { runPointer.curtainAsked = true }
            return !runPointer.curtainAsked
        }
        defer { curtainAsked = true }
        return !curtainAsked
    }

    /// Whose store is meant — `nil` is the device's.
    ///
    /// **No `??` over the container.** `runPointer?.value ?? identifier` looks right and
    /// is not: it packs two questions into one and falls back to the process-wide pointer
    /// as soon as the run explicitly says "the device". A check that runs as the
    /// device base would then get the state of some profile that a neighbouring check
    /// had just set — and would be green one time and red the next.
    public static var active: String? {
        if let runPointer { return runPointer.value }
        return identifier
    }

    /// Is announced when the pointer points to a different person (AP46, 2026-09-25).
    ///
    /// **Until here the pointer was not observable**, and that sufficed: every store asks
    /// it at the moment of reading. The app language, however, is not read when something
    /// is drawn but **held** — at the root, as an environment locale. Without
    /// an announcement it would remain the previous person's after the switch (``AppLanguageSetting``).
    public static let switched = Notification.Name("ProfilePointer.switched")

    /// Sets the pointer. **Only the profile switch calls this** (and the startup, which sets it to
    /// the last chosen one).
    ///
    /// **Only a real switch is announced** — a startup that sets the pointer to the same
    /// value should not re-read a language and not rebuild a tree.
    ///
    /// **In the check run a switch outside ``als(_:_:)`` aborts the run**
    /// (AP58 final step, 2026-09-26). The process-wide pointer would afterwards apply to every
    /// check that runs later in the same process; since shelf order and channel history are
    /// stored per profile (R2, R6), three checks turned red one after another because of that,
    /// each time different ones, depending on order. Sixteen checks in three packages leaked
    /// this way without turning red themselves. The abort names the reason and shows the check in
    /// the stack; in the app it is never active (``inCheckRun``).
    public static func show(to profile: String?) {
        let clean = (profile?.isEmpty ?? true) ? nil : profile
        guard clean != active else { return }
        if let runPointer {
            runPointer.value = clean
        } else {
            if inCheckRun {
                preconditionFailure(
                    leakMessage + "\n" + Thread.callStackSymbols.joined(separator: "\n"))
            }
            identifier = clean
        }
        NotificationCenter.default.post(name: switched, object: nil)
    }

    /// Whether this process is a check run — **there is no process-wide pointer there.**
    ///
    /// Detected by the loaded test library: `swift test` loads `XCTest` also for Swift
    /// Testing (verified on the machine, debug and release build), the app and its
    /// extensions never load it. An environment variable, on the other hand, would be something somebody has to
    /// set — and the one place that forgets it leaks again.
    static let inCheckRun = NSClassFromString("XCTestCase") != nil

    static let leakMessage = """
        ProfilePointer: profile switch in the check run outside ProfilePointer.als(_:_:). \
        The process-wide pointer would afterwards apply to every following check. Wrap the \
        check in `ProfilePointer.als(nil) { … }` — which one it is, the stack below shows.
        """

    /// Runs something as a particular profile — **for checks only.**
    public static func als<Outcome>(
        _ profile: String?, _ run: () throws -> Outcome
    ) rethrows -> Outcome {
        try $runPointer.withValue(RunPointer(profile), operation: run)
    }

    /// The same helper for a flow that waits.
    ///
    /// **`nonisolated(nonsending)` and not `sending`.** `sending` stood here first; with it
    /// the compiler picks the deprecated `withValue` overload with `isolation:`. In the
    /// debug build that is a warning, in the release build (`-warnings-as-errors`) an
    /// error — only the check run noticed, and in all eleven packages at once.
    /// What was meant anyway is what stands here now: the flow continues running where it
    /// was called.
    public static nonisolated(nonsending) func als<Outcome>(
        _ profile: String?, _ run: nonisolated(nonsending) () async throws -> Outcome
    ) async rethrows -> Outcome {
        try await $runPointer.withValue(RunPointer(profile), operation: run)
    }
}
