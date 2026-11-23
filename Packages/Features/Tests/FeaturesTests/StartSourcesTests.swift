import Foundation
import SourceProbe
import Testing

@testable import Features

/// **The Home screen must not be built twice** — 2026-09-23.
///
/// **The finding:** ``MainView/onStart()`` set ``MainView/liveLibrary``,
/// ``MainView/vodSource`` and ``MainView/portalSource`` — and did so **after** the first
/// render, because `.task` only runs once the view stands. Thereby the
/// `SourceState` changed right after startup, ``ShellModels/home(source:provider:portals:channels:anime:rule:)``
/// created a second ``HomeModel``, and `.id(ObjectIdentifier(home))` threw away the
/// standing ``HomeView`` along with its state. The first pass had by then already
/// fetched the catalog over the wire and was cancelled in the middle of it.
///
/// **Why this is a test over the source text and not over behavior.** What goes wrong
/// here is an order in the view tree: when SwiftUI calls `.task` and
/// when `body` is re-evaluated. Both belong to the system and not to us; it could be
/// reproduced only by rebuilding SwiftUI. What can be checked is the rule from which
/// it followed — **the three sources are not set in ``MainView/onStart()``.**
/// The same design as with ``ZustandAnschlussTests`` next door.
///
/// None of the three needs an `await`: they are constructions over the list catalog and
/// the Keychain. They stood there only because the list catalog is a `@StateObject`
/// — and that exists long before the view is built.
@Test("The Home screen sources are not set only at startup")
func startSourcesStandBeforeTheFirstFrame() throws {
    let content = try SourceText.read("MainView.swift", in: .features)
    let rows = content.split(separator: "\n", omittingEmptySubsequences: false)

    guard let start = rows.firstIndex(where: { $0.contains("private func onStart() async {") })
    else {
        Issue.record("beimStart() not found — was the method renamed?")
        return
    }
    // Until the next method at the same level.
    let end =
        rows[(start + 1)...].firstIndex { $0.hasPrefix("    private func ") || $0.hasPrefix("    func ") }
        ?? rows.endIndex

    var found: [String] = []
    for row in rows[start..<end] {
        let raw = row.trimmingCharacters(in: .whitespaces)
        guard !raw.hasPrefix("//"), !raw.hasPrefix("///") else { continue }
        for name in ["liveLibrary =", "vodSource =", "portalSource =", "setPortalSource()"]
        where raw.contains(name) {
            found.append(raw)
        }
    }

    #expect(
        found.isEmpty,
        """
        beimStart() sets the Home screen sources — then the Home screen is built \
        twice: \(found.joined(separator: " | "))
        """)
}
