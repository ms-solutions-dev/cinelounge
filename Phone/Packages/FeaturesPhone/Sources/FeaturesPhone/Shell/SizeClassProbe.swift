import CoreGraphics
import Diagnose
import Foundation
import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

extension View {

    /// Forces the switch **regular → compact → regular** once, so that Split View,
    /// Slide Over and Stage Manager are testable in the simulator at all.
    ///
    /// **Why this probe exists** (AP7): since 2026-09-23 ``MetricClass`` decides
    /// seven numbers by the horizontal size class, and each of these
    /// decisions is visible only in the *other* class. The simulator does not trigger
    /// the switch, though — Split View needs a second app, Stage Manager an
    /// iPadOS window that you have to drag, and neither exists in a run of
    /// `scripts/run.sh`. Without this probe the half-width case stays **unchecked** until
    /// the on-device test, and the on-device test is the place where a defect is
    /// the most expensive to notice.
    ///
    /// **Via the UIKit traits of the root controller and not via the SwiftUI environment.**
    /// ``ShellView`` is a native `TabView` with `Tab`, so under the hood a
    /// `UITabBarController`; it passes the size class on to its contents from its
    /// **own** trait collection. A `.environment(\.horizontalSizeClass, …)`
    /// above it sets only the environment value of the SwiftUI hierarchy and does not arrive in the
    /// tab contents — the same finding that StoryShelf reproduced on 2026-09-19.
    /// `traitOverrides` sits at the place the class actually comes
    /// from.
    ///
    /// **Without the environment variable the modifier does nothing** — it may therefore stay in
    /// the shipped build. `CINELOUNGE_KOMPAKT=<Sekunden>` says how many
    /// seconds after the start the switch comes; then the narrow class holds for
    /// ``SizeClassProbe/holdDuration``, and that is enough for one recording before,
    /// during and after.
    ///
    /// What **must** stay in place in the process: the chosen tab, an open detail on the
    /// stack and the scroll position. A switch that throws you back to Home is
    /// in Split View a data loss and not a cosmetic flaw.
    public func sizeClassProbe() -> some View {
        modifier(SizeClassSwitch())
    }
}

/// The sequence of the probe — and the numbers it calculates with.
///
/// **The probe calculates via ``MetricClass`` and not via numbers of its own.** A probe with
/// its own values proves that it can calculate itself; what it should prove is that **the app**
/// takes different numbers in the narrow class. That is why ``numbers(forItem:)``
/// contains nothing but ``MetricClass`` — whoever changes a number there changes
/// at the same time what the probe writes into the recording.
///
/// Guarded by `scripts/size_classes.py`: every number that ``MetricClass`` decides per
/// size class must occur in ``numbers(forItem:)``. A new number that the
/// probe does not name would be exactly the one nobody checks.
enum SizeClassProbe {

    /// How long the narrow class is held.
    ///
    /// Eight seconds, because a recording from `scripts/run.sh` including the way back via the
    /// system log needs a good three — two seconds would be a race with the
    /// screenshot, and a race in a check is a check that is sometimes
    /// green.
    static let holdDuration: Duration = .seconds(8)

    /// How many seconds after the start the switch comes — or `nil` if this
    /// environment demands no probe.
    ///
    /// **The environment is passed in and not read here.** A `ProcessInfo` in the body
    /// would not be testable, and then the very condition would be unchecked on which
    /// it hangs whether the probe sleeps in the shipped build.
    ///
    /// - Parameter environment: the environment variables of the process.
    static func startup(from environment: [String: String]) -> Duration? {
        guard let value = environment["CINELOUNGE_KOMPAKT"], let seconds = Int(value),
            seconds >= 0
        else { return nil }
        return .seconds(seconds)
    }

    /// The numbers of this size class — name and value, in the order in which they go into
    /// the recording.
    ///
    /// **`nil` stands here as 0 and not as a case of its own.** ``MetricClass/buttonWidth(_:)``
    /// and ``MetricClass/contentCap(_:)`` give `nil` in compact — "no cap". For
    /// a line in the recording the zero is the same: no limit. Two
    /// notations for the same statement would make the recording harder to read and
    /// the comparison of two runs by hand impossible.
    ///
    /// - Parameter sizeClass: the horizontal size class for which it is calculated.
    static func numbers(forItem sizeClass: UserInterfaceSizeClass?) -> [(name: String, value: CGFloat)] {
        [
            ("shelfPosterWidth", MetricClass.shelfPosterWidth(sizeClass)),
            ("columns", CGFloat(MetricClass.columns(sizeClass))),
            ("wideColumns", CGFloat(MetricClass.wideColumns(sizeClass))),
            ("headerBox", MetricClass.headerBox(sizeClass)),
            ("detailColumn", MetricClass.detailColumn(sizeClass)),
            ("buttonWidth", MetricClass.buttonWidth(sizeClass) ?? 0),
            ("contentCap", MetricClass.contentCap(sizeClass) ?? 0),
            ("profileImageColumns", CGFloat(MetricClass.profileImageColumns(sizeClass))),
            ("titleImageHeight", MetricClass.titleImageHeight(sizeClass)),
        ]
    }

    /// The line that goes into the recording per switch.
    ///
    /// It names the numbers and not only the class: a screenshot proves how it
    /// looks, the line proves **what** was calculated with. If the screenshot looks wrong
    /// and the numbers stand there correctly, the fault lies in the view and not in the
    /// table — that is the difference between a finding and a search.
    ///
    /// - Parameter sizeClass: the size class that was just switched to.
    static func row(forItem sizeClass: UserInterfaceSizeClass?) -> String {
        let name = sizeClass == .regular ? "regular" : (sizeClass == .compact ? "compact" : "unknown")
        let numbers = Self.numbers(forItem: sizeClass).map { "\($0.name)=\(Int($0.value))" }
        return "Size class probe → \(name): " + numbers.joined(separator: " ")
    }

    /// Sets the class on all windows of this process.
    @MainActor
    static func force(_ sizeClass: UserInterfaceSizeClass) {
        #if canImport(UIKit)
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            for window in scenes.flatMap(\.windows) {
                window.rootViewController?.traitOverrides.horizontalSizeClass =
                    sizeClass == .compact ? .compact : .regular
            }
        #endif
        Diagnose.step(.surface, Self.row(forItem: sizeClass))
    }
}

/// Attaches the sequence to the view.
///
/// **A `task` and not an `onAppear`.** The switch waits, and waiting in an
/// `onAppear` would mean spawning a loose `Task` that nobody cancels; a `task`
/// ends with the view.
private struct SizeClassSwitch: ViewModifier {

    func body(content: Content) -> some View {
        content
            .task {
                guard
                    let startup = SizeClassProbe.startup(
                        from: ProcessInfo.processInfo.environment)
                else { return }
                try? await Task.sleep(for: startup)
                SizeClassProbe.force(.compact)
                try? await Task.sleep(for: SizeClassProbe.holdDuration)
                SizeClassProbe.force(.regular)
            }
    }
}
