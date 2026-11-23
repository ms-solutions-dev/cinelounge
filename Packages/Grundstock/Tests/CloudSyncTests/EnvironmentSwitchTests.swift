import Foundation
import Testing

@testable import CloudSync

/// **CineLounge, 2026-09-28:** TV as a debug build in "Development", phone from
/// TestFlight in "Production" — separate data. If a device switches the environment, the
/// zone is missing there; that must not count as "deleted remotely".
@Suite("Profile zone: switching the CloudKit environment")
@MainActor
struct EnvironmentSwitchTests {

    let identifier = UUID()

    private func message(_ name: String, _ value: String) -> CloudRecord {
        CloudRecord(contentType: "Profileinstellung", name: name, fields: ["wert": .text(value)])
    }

    private func file() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "environment-\(UUID().uuidString).json")
    }

    @Test("A mirror from Development starts over in Production and uploads everything")
    func restarted() async throws {
        let fileURL = file()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        // Created, synced and confirmed in "Development".
        let development = MockCloud()
        let previous = ProfileZone(
            file: fileURL, service: development.credential("alice", environment: "Development"),
            zone: ZoneID(profile: identifier), automatic: false)
        previous.write(message("name", "Alice"))
        previous.write(message("theme", "indigo"))
        await previous.reconcile()
        #expect(previous.pending == 0)

        // The same mirror, now against "Production", where the zone does not exist.
        let production = MockCloud()
        let after = ProfileZone(
            file: fileURL, service: production.credential("alice", environment: "Production"),
            zone: ZoneID(profile: identifier), automatic: false)
        #expect(after.pending == 2, "everything is queued for upload again")
        await after.reconcile()

        #expect(after.removed == nil, "not declared deleted")
        #expect(after.pending == 0)
        #expect(production.content(ZoneID(profile: identifier, owner: "alice")).count == 2)
        #expect(after.read(contentType: "Profileinstellung", name: "name")?["wert"]?.text == "Alice")
    }

    @Test("In the same environment the guard changes nothing")
    func sameEnvironment() async throws {
        let fileURL = file()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let server = MockCloud()
        let first = ProfileZone(
            file: fileURL, service: server.credential("alice", environment: "Production"),
            zone: ZoneID(profile: identifier), automatic: false)
        first.write(message("name", "Alice"))
        await first.reconcile()

        let reconnectCount = ProfileZone(
            file: fileURL, service: server.credential("alice", environment: "Production"),
            zone: ZoneID(profile: identifier), automatic: false)
        #expect(reconnectCount.pending == 0)
        guard case .synced = reconnectCount.state else {
            Issue.record("State \(reconnectCount.state)")
            return
        }
    }
}
