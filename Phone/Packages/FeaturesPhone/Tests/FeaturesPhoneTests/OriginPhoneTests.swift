import Core
import Foundation
import Testing

@testable import FeaturesPhone

/// **The phone reads the origin of an identifier by the rule in `Core`** (AP58 R6, St8).
struct OriginPhoneTests {

    @Test("Portal, provider and Jellyfin are recognised by their identifier")
    func threeForms() {
        #expect(PlaybackJob.origin(zu: "animehub|serie|morrowfeld") == .portals)
        #expect(PlaybackJob.origin(zu: "liste-1#movie#4711") == .provider)
        #expect(PlaybackJob.origin(zu: "liste-1#episode#22#mkv") == .provider)
        #expect(PlaybackJob.origin(zu: "a1b2c3d4") == .jellyfin)
    }

    @Test("The mapping carries the same raw values", arguments: Core.Origin.allCases)
    func rawValues(origin: Core.Origin) {
        #expect(Catalog.Origin(origin).rawValue == origin.rawValue)
    }
}
