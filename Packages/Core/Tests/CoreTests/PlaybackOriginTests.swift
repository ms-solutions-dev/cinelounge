import Foundation
import Testing

@testable import Core

/// What identifies a running target.
///
/// **The bug checked for here looked like four different bugs on the TV** (viewer
/// finding 2026-08-11): Up and Down no longer switched the channel, the channel list
/// always opened in the first group, the cursor was not on the running channel, and
/// above the programme it said "no programme". All four hung on one line: since the
/// remuxer puts playback on `127.0.0.1`, ``PlaybackTarget/url`` points there — and
/// whoever searches the channel list with it finds nothing.
///
/// This is the second edition of the same bug; the first is at
/// ``ChannelSource/plays(_:)`` and concerned the fallback to the raw stream.
/// That is why the origin now sits in the target itself and is not guessed anew at
/// every place where it is needed.
@Suite("The origin of a playback target")
struct PlaybackOriginTests {

    private func liveTarget(_ address: String) -> PlaybackTarget {
        PlaybackTarget(
            itemID: nil,
            title: "TELVE 1 HEVC",
            url: URL(string: address)!,
            decision: PlaybackDecision(engine: .native, delivery: .remuxInApp, reason: .nativeContainer),
            kind: .live
        )
    }

    @Test("Without a redirect the address is the origin")
    func untouchedTargetIsItsOwnOrigin() {
        let target = liveTarget("http://anbieter:80/live/u/p/1234.m3u8")
        #expect(target.origin == nil)
        #expect(target.sourceURL == target.url)
    }

    @Test("The remuxer moves the address, not the origin")
    func remuxKeepsTheOrigin() {
        let target = liveTarget("http://anbieter:80/live/u/p/1234.m3u8")
        let running = target.rerouted(to: URL(string: "http://127.0.0.1:51234/stream.m3u8")!)

        #expect(running.url.host == "127.0.0.1")
        #expect(running.sourceURL.absoluteString == "http://anbieter:80/live/u/p/1234.m3u8")
    }

    /// **Being redirected twice happens**, and in exactly that case a plain "remember
    /// the previous address" would be wrong: if the remuxer fails, VLC gets the raw
    /// stream — the origin is then the intermediate stop and no longer the channel.
    @Test("The first origin survives the second redirect too")
    func theFirstOriginWins() {
        let target = liveTarget("http://anbieter:80/live/u/p/1234.m3u8")
        let running =
            target
            .rerouted(to: URL(string: "http://127.0.0.1:51234/stream.m3u8")!)
            .rerouted(to: URL(string: "http://127.0.0.1:51234/andere.m3u8")!)

        #expect(running.sourceURL.absoluteString == "http://anbieter:80/live/u/p/1234.m3u8")
    }

    /// This is the finding that explains the four symptoms: with the engine address
    /// ``ChannelSource/plays(_:)`` does **not** find the channel, with the origin it
    /// does. Not even the extension rule takes effect — it compares the address without
    /// extension, and the loopback is a different machine.
    @Test("The channel can only be found again through the origin")
    func onlyTheOriginFindsTheChannel() {
        let channel = Channel(
            id: "c1",
            name: "TELVE 1 HEVC",
            streamURL: URL(string: "http://anbieter:80/live/u/p/1234.m3u8")!,
            playlistID: "p1"
        )
        let running = liveTarget("http://anbieter:80/live/u/p/1234.m3u8")
            .rerouted(to: URL(string: "http://127.0.0.1:51234/1234.m3u8")!)

        #expect(!channel.plays(running.url))
        #expect(channel.plays(running.sourceURL))
    }

    /// **The identifier must not change when switching.** For a channel it is part of
    /// the address; if it changed at the moment the remuxer is up, that would be a
    /// different title to SwiftUI — and the view would rebuild in the middle of the
    /// startup.
    @Test("The identifier stays the same")
    func identityHoldsAcrossReroute() {
        let target = liveTarget("http://anbieter:80/live/u/p/1234.m3u8")
        let running = target.rerouted(to: URL(string: "http://127.0.0.1:51234/stream.m3u8")!)

        #expect(running.id == target.id)
    }
}
