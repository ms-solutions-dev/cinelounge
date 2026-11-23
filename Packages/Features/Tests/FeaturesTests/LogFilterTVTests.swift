import Core
import Foundation
import Testing

@testable import Features

/// **Filter and search in the log on the TV as well** (decision 27, C17) — the same
/// rule as on the phone (``Flows/LogSearch``).
@MainActor
struct LogFilterTVTests {

    private let entries = [
        Diagnostics.Trace.Entry(at: .now, step: "Startseite", target: "/Items", outcome: .started),
        Diagnostics.Trace.Entry(
            at: .now, step: "Wiedergabe", target: "/Videos/1", outcome: .failed("Zeitüberschreitung")),
        Diagnostics.Trace.Entry(
            at: .now, step: "Portale", target: "/portale", outcome: .succeeded("200")),
    ]

    @Test("Only Notable leaves the failures")
    func onlyNotable() {
        let shown = DiagnosticsSettings.filtered(entries, onlyNotable: true, searchTerm: "")
        #expect(shown.map(\.step) == ["Wiedergabe"])
    }

    @Test("The search finds step, target and reason, case-insensitively")
    func search() {
        #expect(
            DiagnosticsSettings.filtered(entries, onlyNotable: false, searchTerm: "PORTALE")
                .map(\.step) == ["Portale"])
        #expect(
            DiagnosticsSettings.filtered(entries, onlyNotable: false, searchTerm: "zeitüber")
                .map(\.step) == ["Wiedergabe"])
        #expect(DiagnosticsSettings.filtered(entries, onlyNotable: false, searchTerm: " ").count == 3)
    }
}
