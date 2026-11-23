import Core
import Foundation
import Testing

@testable import PlaylistKit

/// **The catch-up — 51 of 5389 channels can do it** (AP14, 2026-09-02).
///
/// The structure of the address is fixed by the Xtream protocol and cannot
/// be queried. A wrongly built address returns no error picture but
/// **the programme before** — that is why every part is tested individually here.
@Suite("Catch-up: the address of a past broadcast")
struct RetrospectTests {

    private var credential: XtreamEndpoint {
        XtreamEndpoint(server: "http://anbieter.example:8080", username: "nutzer", password: "geheim")!
    }

    /// 2026-09-02, 20:15 GMT.
    private var eightFifteenPM: Date {
        var split = DateComponents()
        split.year = 2026
        split.month = 9
        split.day = 2
        split.hour = 20
        split.minute = 15
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "GMT")!
        return calendar.date(from: split)!
    }

    @Test("The address carries duration, start and identifier in their place")
    func addressCarriesEverythingInOrder() throws {
        let url = try #require(
            credential.timeshiftURL(streamID: 4711, start: eightFifteenPM, minutes: 90))

        #expect(
            url.absoluteString
                == "http://anbieter.example:8080/timeshift/nutzer/geheim/90/2026-09-02:20-15/4711.m3u8"
        )
    }

    /// **The colon between day and hour is not a typo.** No
    /// common pattern writes it like that; whoever uses `ISO8601` here gets an
    /// address that the server accepts and answers with the wrong hour.
    @Test("The timestamp is in the provider format, two-digit")
    func stampUsesTheProviderFormat() {
        var split = DateComponents()
        split.year = 2026
        split.month = 1
        split.day = 5
        split.hour = 7
        split.minute = 3
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "GMT")!
        let earlyYear = calendar.date(from: split)!

        #expect(
            Catchup.stamp(earlyYear, in: TimeZone(identifier: "GMT")!)
                == "2026-01-05:07-03")
    }

    /// **The time zone decides the programme.** With one hour
    /// of difference, a locally calculated address fetches the programme before —
    /// and without any error message.
    @Test("A different time zone yields a different hour")
    func timeZoneChangesTheHour() {
        let gmt = Catchup.stamp(
            eightFifteenPM, in: TimeZone(identifier: "GMT")!)
        let berlin = Catchup.stamp(
            eightFifteenPM, in: TimeZone(identifier: "Europe/Berlin")!)

        #expect(gmt == "2026-09-02:20-15")
        #expect(berlin == "2026-09-02:22-15")
    }

    /// A recording of zero minutes would be an address the server can
    /// only reject — better none then.
    @Test("Without a duration no address is created")
    func noDurationNoAddress() {
        #expect(credential.timeshiftURL(streamID: 1, start: eightFifteenPM, minutes: 0) == nil)
        #expect(credential.timeshiftURL(streamID: 1, start: eightFifteenPM, minutes: -30) == nil)
    }

    /// **Username and password are path components, not query values** —
    /// the same rule as for the running channel. An encoded slash
    /// would become `%2F`, and the server would not find the path.
    @Test("A password with special characters stays in the path as it is")
    func passwordStaysInThePath() throws {
        let credential = try #require(
            XtreamEndpoint(server: "http://a.example", username: "u", password: "p+q"))
        let url = try #require(
            credential.timeshiftURL(streamID: 9, start: eightFifteenPM, minutes: 30))

        #expect(url.absoluteString.contains("/u/p+q/30/"))
    }
}
