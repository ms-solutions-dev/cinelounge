import Foundation
import Testing

@testable import Core

/// Whether the player finds the running channel again.
///
/// **What is secured here was a failure at two places at once** (viewer finding
/// 2026-08-08): Since the silent fallback to the raw stream the player gets `…/1234.ts`,
/// while the channel list has `…/1234.m3u8`. The equality test of the time then found
/// no channel at all — and both things that need it failed: the program overlay (it
/// stood at "loading" without ever asking) and the switch with up/down.
@Suite("Channel at the current address")
struct ChannelPlaysTests {

    private func channel(_ address: String) -> Channel {
        Channel(
            id: "c1",
            name: "TELVE 1",
            streamURL: URL(string: address)!,
            playlistID: "p1"
        )
    }

    @Test("The same address")
    func exactMatch() {
        let subject = channel("http://host:80/live/u/p/1234.m3u8")
        #expect(subject.plays(URL(string: "http://host:80/live/u/p/1234.m3u8")!))
    }

    @Test("The raw stream of the same channel counts as the same")
    func rawFallbackIsStillTheSameChannel() {
        let subject = channel("http://host:80/live/u/p/1234.m3u8")
        #expect(subject.plays(URL(string: "http://host:80/live/u/p/1234.ts")!))
    }

    @Test("And vice versa: entered raw, played as a playlist")
    func theOtherDirectionToo() {
        let subject = channel("http://host:80/live/u/p/1234.ts")
        #expect(subject.plays(URL(string: "http://host:80/live/u/p/1234.m3u8")!))
    }

    @Test("A different channel stays a different one")
    func differentChannelDoesNotMatch() {
        let subject = channel("http://host:80/live/u/p/1234.m3u8")
        #expect(!subject.plays(URL(string: "http://host:80/live/u/p/9999.ts")!))
    }

    /// The extensions must not be offset arbitrarily: Swapping happens only between
    /// playlist and raw stream. A title that happens to lie under the same path with a
    /// different extension is different content.
    @Test("Foreign extensions are not matched")
    func unrelatedExtensionsStayApart() {
        let subject = channel("http://host:80/live/u/p/1234.m3u8")
        #expect(!subject.plays(URL(string: "http://host:80/live/u/p/1234.mp4")!))
        #expect(!subject.plays(URL(string: "http://host:80/live/u/p/1234.mkv")!))
    }

    @Test("A different host is a different channel")
    func differentHostDoesNotMatch() {
        let subject = channel("http://host:80/live/u/p/1234.m3u8")
        #expect(!subject.plays(URL(string: "http://other:80/live/u/p/1234.ts")!))
    }
}
