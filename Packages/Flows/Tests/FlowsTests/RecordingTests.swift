import Core
import Foundation
import SourceProbe
import Testing

@testable import Flows

/// The switch for detailed recording — **one version for both devices.**
///
/// `.serialized`, because `DebugMode.current` is a value for the whole program: two
/// checks that set it at the same time would read the other's value.
@Suite("Recording", .serialized)
@MainActor
struct RecordingTests {

    @Test("The initial value comes from the store, not from the running program")
    func initialValueFromStore() {
        let store = InMemoryStore()
        DebugMode(isOn: true).save(to: store)
        DebugMode.current = DebugMode(isOn: false)

        #expect(CaptureRecording(store: store).on)
    }

    /// The error that existed on the phone until 2026-09-06: the switch showed On, and
    /// the app recorded sparingly, because only one of the places was set.
    @Test("Flipping sets store and valid state at once", arguments: [true, false])
    func togglingSetsBoth(fresh: Bool) {
        let store = InMemoryStore()
        DebugMode(isOn: !fresh).save(to: store)
        DebugMode.current = DebugMode(isOn: !fresh)
        defer { DebugMode.current = DebugMode() }

        let toggle = CaptureRecording(store: store)
        toggle.setEnabled(fresh)

        #expect(toggle.on == fresh)
        #expect(DebugMode.load(from: store).isOn == fresh)
        #expect(DebugMode.current.isOn == fresh)
    }

    /// **On-device test build 1332, finding 9:** "Open state showcase" was in the TestFlight build
    /// in the diagnostics — a developer showcase of all states. It appears only while
    /// the "record in detail" switch is on, and both apps ask the same place.
    @Test("The state view shows only when recording is on")
    func stateInspectorOnlyInDeveloperMode() throws {
        let store = InMemoryStore()
        defer { DebugMode.current = DebugMode() }
        let toggle = CaptureRecording(store: store)
        #expect(!toggle.showsDeveloperTools)
        toggle.setEnabled(true)
        #expect(toggle.showsDeveloperTools)
    }

    @Test("Both diagnostics views ask the switch before offering the state view")
    func bothViewsAsk() throws {
        let paths = [
            "Packages/Features/Sources/Features/Settings/DiagnosticsSettings.swift",
            "Phone/Packages/FeaturesPhone/Sources/FeaturesPhone/Settings/DiagnoseView.swift",
        ]
        for path in paths {
            let text = try String(
                contentsOf: SourceText.stem.appending(path: path), encoding: .utf8)
            #expect(text.contains("if recording.showsDeveloperTools"), "\(path)")
        }
    }
}
