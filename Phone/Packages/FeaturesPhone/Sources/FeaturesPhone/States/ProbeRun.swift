import DesignSystemPhone
import Foundation
import SwiftUI

/// The views that exist only for inspection — and how to reach them.
///
/// **Why they branch off before the shell and not inside it** (seen on 2026-09-05 in the simulator:
/// a black screen). The probes hung in the ``TabPlaceholder``, that is, behind the tab bar.
/// Since the stay comes from the environment, an app without a configured source has **no
/// tabs** — and thus no placeholder in which a probe could have appeared. Of all cases, the one
/// you want to look at was the only one in which it did not work.
///
/// Three probes, three questions:
///
/// * ``BarProbe`` — which tabs and shelves a setup yields (AP4, AP11)
/// * ``StateProbe`` — whether airplane mode answers differently **per source** (AP8)
/// * ``StateShowcase`` — all nineteen states in their host view (AP15)
public enum ProbeRun {

    /// The probe this environment asks for — or `nil` for the ordinary run.
    ///
    /// **One name with one value, not three names.** Until 2026-09-05 this spot read
    /// `CINELOUNGE_LEISTENPROBE` and `CINELOUNGE_ZUSTANDSPROBE`, while `scripts/run.sh` passed
    /// `CINELOUNGE_PROBE` through — so the probes were **not reachable at all** via the ordinary
    /// path into the simulator, and nobody noticed because you can start them by hand with
    /// `simctl launch`. Two lists of names that have to match drift apart; one list does not.
    public static var requested: ProbeScreen? {
        ProbeScreen(rawValue: ProcessInfo.processInfo.environment["CINELOUNGE_PROBE"] ?? "")
    }

    public enum ProbeScreen: String, Sendable, CaseIterable {
        /// Which tabs and shelves a setup yields.
        case bars = "leisten"
        /// Whether the location lines answer differently per source.
        case locations = "orte"
        /// All nineteen states in their host view.
        case states = "zustaende"
    }
}

/// Shows the requested probe.
public struct ProbeView: View {

    private let which: ProbeRun.ProbeScreen

    public init(_ which: ProbeRun.ProbeScreen) {
        self.which = which
    }

    public var body: some View {
        switch which {
        // The showcase brings its own tab bar and therefore must **not** go into a scroll view: A bar
        // that scrolls along is not one.
        case .states:
            StateShowcase()
        case .bars:
            ScrollView { BarProbe() }.background(ColorRole.reason.color)
        case .locations:
            ScrollView { StateProbe() }.background(ColorRole.reason.color)
        }
    }
}
