import Foundation
import SourceProbe
import Testing

/// **The TV enters the setup only through ``Flows/SetupGate``, and the old sign-in stays gone**
/// (AP88 wave 5) — source guards, because `RootView` is tvOS UI in the app target that
/// `swift test` does not draw.
///
/// Counter-checks: a `LoginView(` anywhere in the TV app turns ``noOldSignIn()`` red; a third
/// `SetupView(` in `RootView`, or a journey not built by `SetupShell`, turns
/// ``rootEntersOnlyThroughShell()`` red; `SetupShell.start()` without `SetupWorld.start(`, or
/// `SetupWorld.start` without `SetupGate.entry(`, turns ``shellAsksTheGate()`` red.
@Suite("Setup — the only entry")
struct SetupEntryGuardTests {

    static let oldNames = ["Login" + "View", "Login" + "Model", "NewAccount" + "View("]

    @Test("The old sign-in screen, its model and the child-account question do not come back")
    func noOldSignIn() throws {
        for file in try SourceText.files(in: .tvApp) {
            let text = file.content.replacingOccurrences(of: "Playlist" + "LoginView", with: "")
            for name in Self.oldNames {
                #expect(!text.contains(name), "\(file.relative) uses \(name)")
            }
        }
        let root = try SourceText.read("RootView.swift", in: .tvApp)
        #expect(!root.contains("fullScreenCover"), "RootView presents nothing of its own any more")
    }

    @Test("RootView shows the setup only for a journey that SetupShell built")
    func rootEntersOnlyThroughShell() throws {
        let root = try SourceText.read("RootView.swift", in: .tvApp)
        #expect(root.components(separatedBy: "SetupView(").count == 3, "first setup and retrofit")
        #expect(!root.contains("SetupJourney("), "no journey of its own")
        #expect(!root.contains("SetupMachine("), "no machine of its own")
        let assignments = root.split(separator: "\n").filter {
            $0.contains("journey = ") && !$0.contains("journey = nil") && !$0.contains("//")
        }
        for line in assignments {
            #expect(
                line.contains("SetupShell.") || line.contains("= running"),
                "a journey from elsewhere: \(line.trimmingCharacters(in: .whitespaces))")
        }
        #expect(
            root.contains(
                "SetupShell.takeLaunchStart() ?? (account.landing == .setup ? SetupShell.start() : nil)"))
    }

    @Test("SetupShell asks the gate, and the gate is SetupGate")
    func shellAsksTheGate() throws {
        let shell = try SourceText.read("SetupShell.swift", in: .tvApp)
        let start = try #require(shell.range(of: "static func start() -> SetupMachine.Start? {"))
        #expect(shell[start.upperBound...].prefix(600).contains("SetupWorld.start("))
        let world = try SourceText.read("Setup/SetupWorld.swift", in: .packets)
        let entry = try #require(world.range(of: "public static func start("))
        #expect(world[entry.upperBound...].prefix(400).contains("SetupGate.entry("))
        #expect(
            shell.components(separatedBy: "SetupMachine(").count == 3,
            "the first setup and the retrofit, both in SetupShell")
    }
}
