import Foundation
import Testing

@testable import Core

/// **The catch-up from the channel address** (AP14, 2026-09-02).
///
/// The channel list knows no access, only its channels — and a channel carries its
/// address along. What becomes of it here decides whether a press on a past entry
/// fetches the recording or leads nowhere.
@Suite("Catch-up from the channel address")
struct ReviewCoreTests {

    private var start: Date {
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

    private func channel(archive: Int?) -> Channel {
        Channel(
            id: "k", name: "Sender", streamURL: URL(string: "http://a.example/live/u/p/4711.ts")!,
            playlistID: "liste", archiveDays: archive)
    }

    @Test("The live address becomes the catch-up address")
    func liveAddressBecomesTimeshift() throws {
        let url = try #require(
            Catchup.address(
                fromLive: URL(string: "http://a.example:8080/live/nutzer/geheim/4711.ts")!,
                start: start, minutes: 90))

        #expect(
            url.absoluteString
                == "http://a.example:8080/timeshift/nutzer/geheim/90/2026-09-02:20-15/4711.m3u8")
    }

    /// **A channel from a plain M3U has no catch-up** — and that is not a malfunction
    /// but information: the view must not even offer it.
    @Test("A foreign-built address yields no catch-up")
    func foreignAddressYieldsNothing() {
        for address in [
            "http://a.example/stream/4711.ts",
            "http://a.example/movie/u/p/4711.mkv",
            "http://a.example/live/u/p/.ts",
        ] {
            #expect(
                Catchup.address(fromLive: URL(string: address)!, start: start, minutes: 30)
                    == nil, "\(address)")
        }
    }

    @Test("The channel's extension does not matter — m3u8 comes out")
    func extensionOfTheLiveAddressDoesNotMatter() throws {
        for fileExtension in ["ts", "m3u8", ""] {
            let point = fileExtension.isEmpty ? "" : ".\(fileExtension)"
            let url = try #require(
                Catchup.address(
                    fromLive: URL(string: "http://a.example/live/u/p/9\(point)")!,
                    start: start, minutes: 30))
            #expect(url.pathExtension == "m3u8")
            #expect(url.absoluteString.hasSuffix("/9.m3u8"))
        }
    }

    // MARK: - Ob überhaupt

    @Test("Without archive days there is no catch-up")
    func noArchiveDaysNoRecording() {
        #expect(
            !Catchup.isInArchive(
                channel(archive: nil), start: start, now: start.addingTimeInterval(3600)))
        #expect(
            !Catchup.isInArchive(
                channel(archive: 0), start: start, now: start.addingTimeInterval(3600)))
    }

    /// **The provider promises more than it keeps** — but what lies beyond the promised
    /// days the app does not even have to try.
    @Test("What is older than the archive is not offered")
    func beyondTheArchiveIsNotOffered() {
        let channel = channel(archive: 3)
        #expect(Catchup.isInArchive(channel, start: start, now: start.addingTimeInterval(3600)))
        #expect(
            Catchup.isInArchive(
                channel, start: start, now: start.addingTimeInterval(2 * 24 * 3600)))
        #expect(
            !Catchup.isInArchive(
                channel, start: start, now: start.addingTimeInterval(4 * 24 * 3600)))
    }

    /// A broadcast that is still running or has yet to come is not a recording.
    @Test("The future is not in the archive")
    func theFutureIsNoRecording() {
        #expect(
            !Catchup.isInArchive(
                channel(archive: 3), start: start, now: start.addingTimeInterval(-60)))
    }
}
