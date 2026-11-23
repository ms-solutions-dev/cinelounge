import Foundation
import SourceProbe
import Testing

@testable import FeaturesPhone

/// **The tabs become a sidebar on the iPad** — AP7, 2026-09-24.
///
/// On the iPad, iPadOS laid the five tabs as a floating capsule centered over the
/// content. `.sidebarAdaptable` lets them become a sidebar in regular; in
/// compact — on the phone and in the half-width window — the bar stays at the bottom.
///
/// **It is checked on the source text**, because the arrangement only arises in the running
/// `UITabBarController`. The line is easy to lose: A rebuild of the wrapper
/// that rewrites the `TabView` does not take a modifier at the end along by itself,
/// and on the phone the loss would never be seen.
@Test("The tab bar may become the sidebar")
func tabBarIsSidebarCapable() throws {
    let code = try SourceText.read("ShellView.swift", in: .featuresPhone)
        .split(separator: "\n").map(String.init)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }

    #expect(
        code.contains { $0.contains(".tabViewStyle(.sidebarAdaptable)") },
        """
        ShellView.swift no longer sets `.tabViewStyle(.sidebarAdaptable)` — on the iPad \
        the five tabs would again float as a capsule above the content.
        """)
}
