import DesignSystem
import SwiftUI

/// A minimal example to test the sidebar on its own.
///
/// Why this is needed: the app's section picker appears as a bar at the **top** edge,
/// although `.tabViewStyle(.sidebarAdaptable)` is set and both exist in the tvOS SDK.
/// Two hypotheses have already been refuted — the style is not missing, and a
/// surrounding navigation frame was not it either.
///
/// Continuing to guess about the whole only costs time. So here the opposite: **as
/// little as possible.** Three tabs, no groups, no navigation frame, no custom
/// backgrounds, no loaded data.
///
/// - If a bar appears at the left edge here, it is down to our setup.
/// - If it appears at the top here too, tvOS ignores the style, and a custom
///   implementation is needed.
///
/// Start it via the environment so that nothing in the app itself has to be changed:
///
/// ```sh
/// SIMCTL_CHILD_CINELOUNGE_PROBE=sidebar \
///   xcrun simctl launch <gerät> dev.ms-solutions.cinelounge
/// ```
public struct SidebarProbe: View {

    /// Which probe was requested, if any.
    public static var requested: Kind? {
        Kind(rawValue: ProcessInfo.processInfo.environment["CINELOUNGE_PROBE"] ?? "")
    }

    public enum Kind: String {
        /// Only the sidebar, as plain as possible.
        case sidebar
        /// Sidebar **and** pill on top of each other — two levels, as intended in the app:
        /// the sections outside, the media library inside.
        case hybrid
    }

    private let kind: Kind

    enum Where: Hashable {
        case first, second, third
    }

    @State private var selection: Where = .first

    public init(_ kind: Kind = .sidebar) {
        self.kind = kind
    }

    public var body: some View {
        switch kind {
        case .sidebar: sidebarOnly
        case .hybrid: hybrid
        }
    }

    // MARK: - Sidebar only

    private var sidebarOnly: some View {
        TabView(selection: $selection) {
            Tab("Eins", systemImage: "house", value: Where.first) {
                page("Eins", .red)
            }
            Tab("Zwei", systemImage: "tv", value: Where.second) {
                page("Zwei", .green)
            }
            Tab("Drei", systemImage: "gearshape", value: Where.third) {
                page("Drei", .blue)
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }

    // MARK: - Both stacked

    /// The question answered here: **can two section pickers be nested** — the sidebar
    /// outside, the pill at the top edge inside?
    ///
    /// The doubt is justified. Both want the press left for themselves: the pill to switch
    /// to the left tab, the sidebar to expand. And both bring their own safe-area
    /// insets. Whether tvOS resolves this cleanly decides whether the app can be built this
    /// way or whether the pill has to be rebuilt by hand.
    private var hybrid: some View {
        TabView(selection: $selection) {
            Tab("Jellyfin", systemImage: "play.tv", value: Where.first) {
                inner
            }
            Tab("Suche", systemImage: "magnifyingglass", value: Where.second) {
                page("Suche", .green)
            }
            Tab("Einstellungen", systemImage: "gearshape", value: Where.third) {
                page("Einstellungen", .blue)
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }

    /// The inner level: an ordinary pill, no special style.
    private var inner: some View {
        TabView {
            Tab("Start", systemImage: "house") {
                page("Start", .red)
            }
            Tab("Serien", systemImage: "tv") {
                page("Serien", .orange)
            }
            Tab("Filme", systemImage: "film") {
                page("Filme", .purple)
            }
        }
    }

    /// Strong flat colours instead of designed content: on a recording it is immediately
    /// visible where the bar sits and how much space it takes.
    private func page(_ title: String, _ tint: Color) -> some View {
        ZStack {
            tint.opacity(0.35).ignoresSafeArea()
            // festeschrift: test view for screen recordings, never visible in the app.
            VStack(spacing: 20) {
                Text(verbatim: title)
                    .font(.system(size: 90, weight: .bold))
                Text(verbatim: "Sidebar on the left? Then the style holds.")
                    .font(.system(size: 30))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
