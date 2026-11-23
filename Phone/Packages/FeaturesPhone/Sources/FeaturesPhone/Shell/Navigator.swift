import Observation
import ParentalControls

/// Where "Back" leads — and with which word.
///
/// **Not blanket to Home.** Every tab has its own stack and keeps it when switching;
/// whoever goes from the library into a detail page, switches to the Live tab
/// and comes back, is in the detail page again.
///
/// Overlaid views (setup, accounts, parental controls, settings) lie
/// **above** the tab bar and have a stack of their own. For each one it is remembered
/// **through which door** you came: diagnostics can be reached from setup and from
/// Settings, and the way back carries the word of the door — not that of the
/// most recently visited view.
@MainActor
@Observable
public final class Navigator {

    /// The selected tab.
    public var tabs: Tab = .start

    /// The stack per tab. It stays in place when switching.
    private var stack: [Tab: [ViewPath]] = [:]

    /// What lies above the tab bar.
    ///
    /// **Since 2026-09-07 with a setter, so that a `NavigationStack` can drive it.** Until
    /// then ``OverlaidView`` only rendered `overlay.last` into a stack without
    /// `path:` — and so there was neither a push transition nor the edge swipe gesture nor
    /// a place for a title. The tabs have always done it right
    /// (``ShellModel/path(forItem:)``); the overlay was the only stack of the app
    /// that was none.
    ///
    /// **The setter is deliberately narrow.** It takes only what SwiftUI hands back on
    /// swiping back — a **truncation**. Whoever appended a view with it would bypass
    /// the gate guard; that is why adding still goes through ``show(_:)`` alone.
    public var overlay: [ViewID] {
        get { overlayStack }
        set {
            guard newValue.count < overlayStack.count else { return }
            for removed in overlayStack.dropFirst(newValue.count) {
                door[removed] = nil
                if removed == .forgotPin { inFallback = false }
            }
            overlayStack = newValue
        }
    }

    private var overlayStack: [ViewID] = []

    /// For each overlaid view the door through which you came.
    private var door: [ViewID: ViewID] = [:]

    public init() {}

    // MARK: - The gatekeeper

    /// Whoever asks before every door whether it is closed.
    ///
    /// **The lock stands in ONE place and not in forty.** Every path of this app
    /// runs through ``show(_:)``; whoever wrote the check into the views instead
    /// would have it in forty places and, at the next screen, in thirty-nine — and
    /// that was exactly the most serious finding of the usability pass: **four taps**
    /// from the child account to the "Adult channels" switch, without a PIN.
    ///
    /// It returns the ``PinTask`` with which the sheet opens, or `nil` if the
    /// path is free. **A request and not a `Bool`**: without it the keypad would
    /// stand there without a sentence, and nobody would know what it currently unlocks.
    public var gatekeeper: (@MainActor (ViewID) -> PinTask?)?

    /// Which views **do not exist at all** — for a child without a device PIN the management
    /// (``KidsTargets``). Unlike the ``gatekeeper`` it asks nothing: the path ends silently.
    public var lock: (@MainActor (ViewID) -> Bool)?

    /// The one stack currently visible, **if there is only one** — otherwise `nil`.
    ///
    /// **Finding H1 of the check (2026-09-27), the same as on 12. and 2026-09-13:** without a network
    /// the shell shows only the library's stack. ``create(_:job:)`` however wrote into
    /// the stack of the selected tab, and that was `.start` after launch — a tap
    /// on a downloads poster landed where nobody sees it. ``ShellModel/enterDownloadsAlone()``
    /// was built and had no caller. **That is why every step asks for itself**: whether the
    /// view has already switched the tab is then no longer a question of order.
    public var onlyStack: (@MainActor () -> Tab?)?

    /// Clears away what is currently not reachable — **overlay and stack, each from the
    /// first locked view.** After a switch to a child profile the child would
    /// otherwise still be in the Settings that the adult left open.
    public func clearBlocked() {
        guard let lock else { return }
        if let first = overlayStack.firstIndex(where: { lock($0) }) {
            for view in overlayStack[first...] { door[view] = nil }
            overlayStack.removeSubrange(first...)
        }
        for (tabs, route) in stack {
            guard let first = route.firstIndex(where: { lock($0.view) }) else { continue }
            for removed in route[first...] { payload[removed] = nil }
            stack[tabs] = Array(route[..<first])
        }
    }

    /// What the PIN is currently being asked for — `nil` means: for nothing.
    public private(set) var waiting: PinTask?

    /// Whether the "forgot PIN" escape is open. **The request keeps waiting meanwhile.**
    ///
    /// **The prototype checked itself at this point:** a first version
    /// deleted the request when turning into the escape — four digits then did nothing,
    /// and whoever types the right PIN and sees nothing believes they mistyped.
    public private(set) var inFallback = false

    /// Where it goes after the PIN is passed.
    private var pinTarget: ViewID?

    /// Or what happens then — for doors that are not a view (account switch).
    private var pinAfterwards: (@MainActor () -> Void)?

    /// The request waiting behind the door.
    ///
    /// **It must survive the question.** Until 2026-09-07. ``show(_:job:)`` stored the
    /// payload before the gate guard, because it hung on the view kind and simply
    /// stayed there. Since it hangs on the stack slot, the slot does not yet exist at the time of
    /// the question — the request therefore waits here along with it.
    private var pinPayload: PlaybackJob?

    /// Whether the PIN sheet should open right now.
    public var asksForPin: Bool { waiting != nil && !inFallback }

    /// Asks for the PIN for something that is **not** a view.
    ///
    /// The account switch in the person sheet is the case this exists for: it leads
    /// nowhere and nevertheless removes every limit.
    public func query(_ job: PinTask, following: @escaping @MainActor () -> Void) {
        waiting = job
        pinTarget = nil
        pinAfterwards = following
    }

    /// The PIN was correct — **the one action it was given for.**
    public func letPass() {
        let target = pinTarget
        let job = pinPayload
        let following = pinAfterwards
        waiting = nil
        pinTarget = nil
        pinPayload = nil
        pinAfterwards = nil
        if let target { create(target, job: job) }
        following?()
    }

    /// Turned back at the door.
    public func giveUp() {
        waiting = nil
        pinTarget = nil
        pinPayload = nil
        pinAfterwards = nil
        inFallback = false
    }

    /// The escape for the parent who has forgotten their PIN.
    ///
    /// **It leaves the request standing.** Whoever comes back from there finds the same question
    /// again — see ``inFallback``.
    public func showFallback() {
        guard waiting != nil else { return }
        inFallback = true
        door[.forgotPin] = current
        overlayStack.append(.forgotPin)
    }

    /// The path within the selected tab.
    public var path: [ViewPath] {
        get { self[tabs] }
        set { self[tabs] = newValue }
    }

    /// The path of **a specific** tab.
    ///
    /// **The finding of 2026-09-05** The shell gave every `NavigationStack` the same binding,
    /// and that read ``path`` — that is, the stack of the *currently selected* tab. All five
    /// stacks thus hung on one. It went unnoticed for a long time, because SwiftUI rebuilds on
    /// switching back; it becomes visible as soon as a tab disappears **while** being
    /// displayed — and it can, since the bar follows the setup.
    public subscript(tabs: Tab) -> [ViewPath] {
        get { stack[tabs] ?? [] }
        set { stack[tabs] = newValue }
    }

    /// The view that is currently visible.
    public var current: ViewID {
        overlay.last ?? path.last?.view ?? tabView
    }

    /// Only the views of the stack, without their slots.
    ///
    /// For everything that wants to know **what** is open and not which call it came from.
    public func views(_ tabs: Tab) -> [ViewID] {
        self[tabs].map(\.view)
    }

    /// The root view of the selected tab.
    public var tabView: ViewID { tabs.root }

    /// What belongs to the view that is just being opened.
    ///
    /// **At the wayfinder and not at the view**, because it drives the stack: whoever goes from one
    /// detail page into the next and back must find both again. One payload
    /// per stack slot, not one for all.
    ///
    /// **Since 2026-09-07 the body also honors this promise.** Until then the
    /// key was the ``ViewID`` — that is, one payload for **all** detail pages,
    /// exactly the opposite of the sentence above. Two titles shared a slot, and
    /// whoever opened the second saw the first. The key is now the
    /// ``ViewPath``, and it carries the stack slot.
    ///
    /// **A ``PlaybackJob`` and no string — direction K6a of 2026-09-06** Until then it was
    /// `[ViewID: String]`, and whoever received the identifier had to guess
    /// where it came from. Two of five tabs therefore had no playback path at all.
    /// What travels along is now identifier **and** origin **and** start position.
    private var payload: [ViewPath: PlaybackJob] = [:]

    /// Leads into a view — with the request it is about.
    public func show(_ view: ViewID, job: PlaybackJob) {
        guard lock?(view) != true else { return }
        if let query = gatekeeper?(view) {
            waiting = query
            pinTarget = view
            pinPayload = job
            pinAfterwards = nil
            return
        }
        create(view, job: job)
    }

    /// Leads into a view — with an identifier whose origin is read.
    ///
    /// For everything that comes from a tile. The Live tab does **not** use this path:
    /// a channel identifier carries no feature, see ``PlaybackJob/origin(zu:)``.
    public func show(_ view: ViewID, title identifier: String) {
        show(view, job: PlaybackJob(identifier: identifier))
    }

    /// The request that belongs to this stack slot.
    public func job(zu route: ViewPath) -> PlaybackJob? { payload[route] }

    /// Only the identifier — for views that have no use for the origin.
    public func title(zu route: ViewPath) -> String? { payload[route]?.identifier }

    /// Leads into a view.
    ///
    /// An overlay lands on the overlay stack, everything else in the stack of the selected
    /// tab. The door is remembered in the process.
    public func show(_ view: ViewID) {
        guard lock?(view) != true else { return }
        // **The question is asked at the door.** If the path is open — or a
        // ``Pass`` applies to it —, the gate guard returns `nil` and things go on as always.
        if let job = gatekeeper?(view) {
            waiting = job
            pinTarget = view
            pinAfterwards = nil
            return
        }
        create(view, job: nil)
    }

    /// Stores the view — **without the gate guard**, which has already asked beforehand.
    ///
    /// The one place where a stack slot comes into being. It has to be, because the payload
    /// hangs on this slot and not on the view kind: whoever appended past it
    /// would have a slot without a request.
    private func create(_ view: ViewID, job: PlaybackJob?) {
        if view.isOverlay || continuesInOverlay(view) {
            door[view] = current
            overlayStack.append(view)
            return
        }
        if let sole = onlyStack?(), sole != tabs { tabs = sole }
        var route = stack[tabs] ?? []
        let slot = ViewPath(view, slot: route.count)
        route.append(slot)
        stack[tabs] = route
        // **`nil` is written too, and that is the point.** On swiping back
        // SwiftUI shortens the path itself, without ``back()`` — the request of the
        // cleared slot then stays around. Whoever later fills the same slot without
        // a request would find it again and show a title that nobody
        // called. Exactly the error this refactoring removes.
        payload[slot] = job
    }

    /// **Whoever is in the overlay continues in the overlay.**
    ///
    /// **The client's finding of 2026-09-09, on screen:** tapping "Storage" in
    /// Settings opened the view only after tapping "Done". And that is exactly how it was:
    /// the step took place, just one level too deep.
    ///
    /// **Why Storage of all things.** ``ViewID/isOverlay`` is read off the
    /// tab, and ``ViewID/storage`` is the **only** one of the eleven
    /// settings sections that has one — it belongs to the library, because it can also be reached from
    /// the downloads. So it landed in the stack of the **tab**, and that lies below
    /// the Settings' `fullScreenCover`. It became visible only when "Done" took the
    /// cover away. All three doors to it were affected: the section list, the
    /// account and privacy — only the path from the downloads was right, because there you are in the
    /// library stack anyway.
    ///
    /// **The mapping stays as it is.** Declaring Storage an overlay would have been
    /// the smaller change and the wrong one: it would break the rule
    /// "tab exactly when not on top" and take from the path out of the downloads the
    /// lit library icon. So it is not the view that decides but **where you
    /// are standing** — and that is the question at hand anyway.
    ///
    /// **Player and remote are excluded**, recognized by their missing tab:
    /// they lie over everything and are not left with "Done". Hanging them into
    /// the overlay would mean ending a running picture behind a button that
    /// talks about Settings.
    private func continuesInOverlay(_ view: ViewID) -> Bool {
        !overlayStack.isEmpty && view.tabs != nil
    }

    /// One step back. First the overlay, then the tab stack.
    public func back() {
        if !overlayStack.isEmpty {
            let route = overlayStack.removeLast()
            door[route] = nil
            // Back out of the escape means back into the sheet that was waiting there.
            if route == .forgotPin { inFallback = false }
        } else if let route = stack[tabs]?.popLast() {
            // **The slot goes, its request goes with it.** A request that survives a
            // cleared slot is found the next time the same view opens — and shows a
            // title that nobody called.
            payload[route] = nil
        }
    }

    /// Clears the entire overlay — that is "Done".
    /// Empties the stacks of all tabs — **the overlays stay** (``ShellModel/followRulesState()``).
    public func discardStack() {
        stack = [:]
        payload = [:]
    }

    /// Empties everything: stacks, overlays, a waiting PIN — **like `ChildGuard.discard`
    /// on the TV** (``ShellModel/followRulesState()``).
    public func discardAll() {
        discardStack()
        done()
    }

    public func done() {
        for view in overlayStack { door[view] = nil }
        overlayStack.removeAll()
        // **"Done" also clears the open question.** A request that survived a
        // cleared stack led, the next time a view opened, into a
        // view that nobody called.
        giveUp()
    }

    /// Through which door you came into this view.
    ///
    /// Carries the way-back text: whoever opens diagnostics from setup comes back "to
    /// Setup" and not "to Settings".
    public func doorClosed(_ view: ViewID) -> ViewID? {
        door[view]
    }

    /// The tab that should light up.
    ///
    /// An overlay has none — the tab bar is not visible there at all.
    public var highlightedTab: Tab? {
        overlay.isEmpty ? current.tabs ?? tabs : nil
    }

    /// Brings selection and stack in line with a changed setup.
    ///
    /// **Three rules, and each has a reason:**
    ///
    /// * **The stack of a vanished tab is deleted, not kept.**
    ///   Keeping sounds friendly and is not: whoever deletes a channel list and
    ///   sets up another would otherwise stand in the detail page of a title that does not exist on
    ///   the new provider. The same rule as with the channel reminder of the
    ///   TV schedule — a reminder of something that no longer exists leads nowhere.
    /// * **A remaining stack is cut off at the front, not filtered.** A `filter`
    ///   creates holes, and a hole in the stack is noticed only when going back — then
    ///   you stand in a place that nobody called.
    /// * **The overlay stays.** It lies above the bar and belongs to no tab; the
    ///   setup that is just triggering this change is itself one.
    public func adapt(
        _ state: CatalogState, isInChildMode childMode: Bool = false,
        deselected: Set<String> = []
    ) {
        adapt(
            state, isInChildMode: childMode, deselected: deselected,
            channelApproval: ChannelApproval())
    }

    /// The same adjustment **with the allow list for channels** (tvOS roadmap AP52) — the
    /// shell calls only this one; without a list a child with permitted groups would lose the way into
    /// its Live tab at every change of the setup.
    public func adapt(
        _ state: CatalogState, isInChildMode childMode: Bool, deselected: Set<String>,
        channelApproval: ChannelApproval
    ) {
        let stay = Set(
            state.tabs(
                isInChildMode: childMode, deselected: deselected, channelApproval: channelApproval))
        for tabs in stack.keys where !stay.contains(tabs) {
            for removed in stack[tabs] ?? [] { payload[removed] = nil }
            stack[tabs] = nil
        }
        for (tabs, route) in stack {
            let remains = Array(
                route.prefix {
                    state.reached(
                        $0.view, isInChildMode: childMode, channelApproval: channelApproval)
                })
            for removed in route.dropFirst(remains.count) { payload[removed] = nil }
            stack[tabs] = remains
        }
        if !stay.contains(tabs) {
            tabs =
                state.tabs(
                    isInChildMode: childMode, deselected: deselected,
                    channelApproval: channelApproval
                ).first
                ?? .start
        }
    }
}
