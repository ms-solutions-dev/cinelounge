import Foundation
import Testing

@testable import Core

/// The local deliverer — here only its logging rule.
///
/// **Why the rule exists** (product requirement 2026-08-15): Every single delivery
/// wrote hundreds of lines per film into the recording — "Hollowmark doesn't need a
/// thousand lines". What stays is what gives information: the startup and the persistence.
@Suite("Delivery: the logging rule")
struct LocalMediaServerTests {

    @Test("Header and segment 0 carry the startup, every tenth the continuation")
    func logsOnlyTheTellingDeliveries() {
        #expect(LocalMediaServer.isWorthLogging("header.mp4"))
        #expect(LocalMediaServer.isWorthLogging("segment0.m4s"))
        #expect(LocalMediaServer.isWorthLogging("segment10.m4s"))
        #expect(LocalMediaServer.isWorthLogging("segment120.m4s"))

        #expect(!LocalMediaServer.isWorthLogging("segment1.m4s"))
        #expect(!LocalMediaServer.isWorthLogging("segment7.m4s"))
        #expect(!LocalMediaServer.isWorthLogging("segment99.m4s"))

        // Playlist fetches say nothing — the player fetches them in rhythm.
        #expect(!LocalMediaServer.isWorthLogging("media.m3u8"))
    }
}
