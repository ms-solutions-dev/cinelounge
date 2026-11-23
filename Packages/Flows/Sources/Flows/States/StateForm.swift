import Foundation

/// What a state is on the screen.
///
/// **Forms and not one type with optional fields.** A type with `button: String?`
/// would leave open at every call site whether the button is missing because it is not needed
/// or because someone forgot it. ``InfoVersusAction`` checks exactly this
/// difference — and can do so only if it is in the type.
///
/// An **information state** explains and demands nothing. A **task state** has **exactly one**
/// next step; that its button is not optional is half the rule.
public nonisolated enum StateForm: Sendable, Equatable {
    /// Waits — and says for what.
    case load(LoadingInfo)
    /// Says what is. **Without a loud button, and that is a statement.**
    case info(StateInfo)
    /// Says what is, **and what one can do about it.**
    case job(Job)
    /// Expressly shows **nothing** — the cancellation after a call.
    case muted

    /// Whether this form carries a loud button.
    public var hasButton: Bool {
        if case .job = self { return true }
        return false
    }

    /// The key of the one loud button, or `nil`.
    public var loudButton: String? {
        if case .job(let job) = self { return job.button }
        return nil
    }

    /// Where the loud button leads, or `nil`.
    public var target: ActionTarget? {
        if case .job(let job) = self { return job.target }
        return nil
    }

    /// The heading — **for everything that does not draw the state as a block** (the banner
    /// without network on the phone, the line on the TV). `nil` while loading and in the silent
    /// case: the one waits, the other expressly shows nothing.
    public var headline: String? {
        switch self {
        case .info(let info): info.headline
        case .job(let job): job.headline
        case .load, .muted: nil
        }
    }

    /// The sentence — also while loading, where it is the only thing shown.
    public var message: String? {
        switch self {
        case .info(let info): info.message
        case .job(let job): job.message
        case .load(let load): load.message
        case .muted: nil
        }
    }

    /// The icon — the same question, the same reasoning as for ``headline``.
    public var icon: String? {
        switch self {
        case .info(let info): info.icon
        case .job(let job): job.icon
        case .load, .muted: nil
        }
    }

    /// The quiet path alongside — **one question for all forms and not three.**
    ///
    /// The silent case has none, and that is not a `default`: a `default` would take from the
    /// next case the question of whether it should have one.
    public var sidePath: String? {
        switch self {
        case .info(let info): info.sidePath
        case .job(let job): job.sidePath
        case .load(let load): load.sidePath
        case .muted: nil
        }
    }
}

/// What is being waited for — and what is added after a while.
public nonisolated struct LoadingInfo: Sendable, Equatable {

    /// The sentence that is there from the start — key in the shared catalog.
    public let message: String

    /// Whether the longer version applies immediately — for ``PlaybackPhase/loadingLong``, so that the
    /// state showcase can present it without waiting four seconds.
    public let slowImmediately: Bool

    /// The way out that is added during long loading (on the phone: into the downloads).
    public let sidePath: String?

    /// The second sentence that is added after a while — the same for every loading state.
    public static let slowWording = "state.loading.slow"

    public init(message: String, slowImmediately: Bool = false, sidePath: String? = nil) {
        self.message = message
        self.slowImmediately = slowImmediately
        self.sidePath = sidePath
    }
}

/// An information state — icon, heading, sentence.
public nonisolated struct StateInfo: Sendable, Equatable {
    /// A name from SF Symbols.
    public let icon: String
    public let headline: String
    public let message: String

    /// A path that is **not a task** — as a quiet button under the sentence.
    ///
    /// "Search in Live" demands nothing; it names the one place where the thing sought might
    /// still be. Whoever draws that loudly turns an information state into a problem.
    public let sidePath: String?

    public init(icon: String, headline: String, message: String, sidePath: String? = nil) {
        self.icon = icon
        self.headline = headline
        self.message = message
        self.sidePath = sidePath
    }
}

/// A task state — the same, and **one** button with **one** target.
public nonisolated struct Job: Sendable, Equatable {
    /// A name from SF Symbols.
    public let icon: String
    public let headline: String
    public let message: String

    /// The one next step. Not optional, not several.
    public let button: String

    /// Where the button leads — **as a value that the platform translates into its action.**
    public let target: ActionTarget

    /// A second path that is **not a loud button**. Two equally loud buttons
    /// side by side are no longer a recommendation but a question.
    public let sidePath: String?

    /// Whether this state **costs time or money** — the phone then colors the icon
    /// gold: gold says "this has a price", red says "this is broken".
    public let costs: Bool

    public init(
        icon: String, headline: String, message: String, button: String,
        target: ActionTarget, sidePath: String? = nil, costs: Bool = false
    ) {
        self.icon = icon
        self.headline = headline
        self.message = message
        self.button = button
        self.target = target
        self.sidePath = sidePath
        self.costs = costs
    }
}

/// Where the button of a task state leads.
///
/// **An enumeration and no callback in the value.** A `() -> Void` in the state would mean that
/// ``PlaybackPhase`` could be neither compared nor checked — and that is exactly what
/// ``InfoVersusAction`` needs. **The platform translates the target into an action**, thinly
/// and in one place: on the TV the wrapper (`MainView.go(zu:)`), on the phone the
/// signpost via the environment value `stateRoute`. ``retry`` belongs to the view,
/// because "reload" means something different at every place.
public nonisolated enum ActionTarget: String, Sendable, Equatable, CaseIterable {
    /// Load once more — the same request, nothing else.
    case retry = "erneut"
    case setup = "einrichtung"
    case accounts = "konten"
    case channelLists = "senderlisten"
    case liveSettings = "liveEinstellungen"
    case portalSettings = "portaleEinstellungen"
    /// Trigger the sync.
    case sync = "abgleich"
    /// Open the certificate sheet — the question is already in the mailbox.
    case certificate = "zertifikat"
    /// The downloads rules ("Download on Wi-Fi only") — on the phone only.
    case downloadRules = "vorratsregeln"
    /// The system settings — the only way out of the app, on the phone only.
    case systemSettings = "systemeinstellungen"
}

/// The steps of a path, with the status of each one.
///
/// **The texts live here, the times come from the measurement.** A path probe that ships its
/// durations asserts them — over a line it does not know.
public nonisolated struct RouteProbe: Sendable, Equatable {

    public struct Step: Sendable, Equatable, Identifiable {
        public enum State: Sendable, Equatable { case done, isRunning, failed, pending }

        public let id: String
        /// Key in the shared catalog.
        public let message: String
        public let state: State

        public init(id: String, message: String, state: State) {
            self.id = id
            self.message = message
            self.state = state
        }
    }

    public let steps: [Step]

    public init(_ steps: [Step]) { self.steps = steps }

    /// How many steps already lie behind the viewer.
    ///
    /// **Failed ones count.** A path that was rejected has been tried —
    /// not counting it would leave the display standing while the app keeps working.
    public var done: Int {
        steps.filter { $0.state == .done || $0.state == .failed }.count
    }

    /// The case both showcases present: directly rejected, now via the bridge.
    ///
    /// **An example and not a measurement** — it lives here so that the showcase can show it
    /// without really querying a portal. A query costs, with an account with
    /// one allowed connection, exactly the connection in question.
    public static let fallbackViaBridge = RouteProbe([
        Step(id: "aufgeloest", message: "state.portal.fallback.resolved", state: .done),
        Step(id: "direkt", message: "state.portal.fallback.direct", state: .failed),
        Step(id: "bruecke", message: "state.portal.fallback.bridge", state: .isRunning),
        Step(id: "wiedergabe", message: "state.portal.fallback.play", state: .pending),
    ])
}
