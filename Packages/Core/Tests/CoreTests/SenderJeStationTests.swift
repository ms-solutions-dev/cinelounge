import Foundation
import Testing

@testable import Core

/// **On-device test 2026-09-28:** three times "TR: Ayaz HQ" in "Continue Watching".
@Suite("Continue Watching: one tile per station")
struct ChannelPerStationTests {

    private func channel(_ id: String, _ name: String, epg: String? = "ayaz.tr") -> Channel {
        Channel(
            id: id, name: name, streamURL: URL(string: "http://provider/live/\(id).ts")!,
            playlistID: "list", epgID: epg)
    }

    @Test("Three versions of the same station yield one — the one listed first")
    func threeVersions() {
        let row = [channel("3", "TR: AYAZ HQ"), channel("1", "TR: AYAZ"), channel("2", "TR: AYAZ HD*")]
        #expect(ChannelVariants.perStation(row).map(\.id) == ["3"])
    }

    @Test("Different stations stay")
    func different() {
        let row = [channel("1", "TR: AYAZ"), channel("9", "TR: LODOS", epg: "lodos.tr")]
        #expect(ChannelVariants.perStation(row).count == 2)
    }
}
