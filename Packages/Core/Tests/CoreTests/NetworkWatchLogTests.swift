import Testing

@testable import Core

/// **The TV writes network changes to the log** — finding 11, the same on the TV
/// as on the phone (decision 25).
@Suite("Finding 11 · network change on the TV")
struct NetworkWatchLogTests {

    @Test("Loss and return with the interfaces, without address")
    func message() {
        #expect(
            NetworkWatch.logLine(connected: false, interfaces: ["utun3"])
                == "Network lost · interfaces: utun3")
        #expect(
            NetworkWatch.logLine(connected: true, interfaces: ["en0", "utun3"])
                == "Network back · interfaces: en0, utun3")
        #expect(
            NetworkWatch.logLine(connected: false, interfaces: [])
                == "Network lost · interfaces: none")
    }
}
