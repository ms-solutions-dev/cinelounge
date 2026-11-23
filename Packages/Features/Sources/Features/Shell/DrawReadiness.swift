import Core

/// **"The target view can draw" — the name for the moment at which the intro makes room
/// for the cards** (AP51, 2026-09-24; concept section 3, last sub-item).
///
/// **Who reports, and why exactly these:**
///
/// - **The Home screen**, as soon as ``HomeModel/state`` leaves `.loading`. `.failed`
///   and `.empty` count too: a fault message is a result, and the intro must not cover
///   it. This is the single-profile household — seconds over the line.
/// - **Not "Who's watching?"** (counter-check 2026-09-24). The question appears as a
///   full screen **above** the intro; if it reported on appearing, in a multi-profile
///   household nobody would see a frame of the clip, and the day would be used up
///   anyway. It therefore waits with ``afterIntro(_:)`` until the cover opens for
///   another reason.
/// - **The setup**, when no access exists yet — it needs no network.
///
/// **Whoever does not report falls back on the deadline** (rule L) and never on
/// "never": Live and portals as the first section report nothing today, and there the
/// cards arrive at `cardsAt` at the latest. This is the safe side — a missing reporter
/// costs at most the deadline and extends nothing.
///
/// **A holder of its own and not a callback through ``MainView``:** The reporters sit
/// in three different views, and none of them knows the intro. They only say that they
/// can draw; who waits for that is the entry point's business.
public final class DrawReadiness {

    /// The one for the program run. Tests build their own.
    public static let shared = DrawReadiness()

    /// Whether a report has been made before. **Stays set** — the intro comes only on a
    /// cold start, and afterwards there is nothing more to report.
    public private(set) var reached = false

    private var waiters: [() -> Void] = []
    private var cap: IntroCover?

    init() {}

    /// The target view can draw its first screenful.
    public func notify() {
        guard !reached else { return }
        reached = true
        let now = waiters
        waiters = []
        for action in now { action() }
    }

    /// Calls `action` as soon as it is reported — **immediately** if that has already
    /// happened.
    ///
    /// The immediately is half of the statement: "Who's watching?" can appear before the
    /// intro has registered. Anyone who then waited for the next report would wait until
    /// the deadline.
    public func onReached(_ action: @escaping () -> Void) {
        if reached { action() } else { waiters.append(action) }
    }

    /// **The connection to the cover in one place** — the view calls it, and so does the
    /// test.
    public func connect(_ cap: IntroCover) {
        self.cap = cap
        onReached { cap.reportGlyphReady() }
    }

    /// Calls `action` as soon as the intro releases the view — **immediately** if there
    /// is none.
    ///
    /// **Relies on the order of the entry point:** ``IntroStage`` decides and connects in
    /// its build, before the content below runs its first `.task`.
    public func afterIntro(_ action: @escaping () -> Void) {
        if let cap { cap.afterUncovering(action) } else { action() }
    }
}
