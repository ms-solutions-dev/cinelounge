import Foundation
import SwiftUI

/// The window during which the sidebar is not reachable at **app launch**.
///
/// **Why it exists.** When distributing the initial focus, tvOS picks the
/// sidebar if it finds nothing focusable in the content — and the content is
/// still loading at launch. Anything that is not reachable during distribution
/// does not get the focus; afterwards the sidebar is operable as usual.
///
/// **Why it no longer hangs off the view** (AP4 · K9, expert review 2026-08-24):
/// The wait ran in a `.task` of the sidebar, and that runs again on **every**
/// rebuild of its view identity — after each return from search the sidebar was
/// dead for a quarter of a second for no reason. The window belongs to the app
/// run, not to the view.
public final class EntryWindow: ObservableObject {

    public static let shared = EntryWindow()

    /// How long the sidebar is unreachable at launch.
    ///
    /// A quarter of a second, while the content is still loading anyway.
    public static let duration: Duration = .milliseconds(250)

    /// Whether the window is over. Once `true`, always `true`.
    @Published public private(set) var over = false

    private var isRunning = false

    init(over: Bool = false) {
        self.over = over
    }

    /// Lets the window expire — on the first call, and only then.
    ///
    /// Every further call returns immediately: a second rebuild of the sidebar
    /// must not wait again, and two simultaneous calls must not start two
    /// waits.
    public func open() async {
        guard !over, !isRunning else { return }
        isRunning = true
        try? await Task.sleep(for: Self.duration)
        over = true
        isRunning = false
    }
}
