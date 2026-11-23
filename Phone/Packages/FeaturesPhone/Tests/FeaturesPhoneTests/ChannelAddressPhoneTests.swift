import Core
import Foundation
import Testing

@testable import FeaturesPhone

/// **The address half of channel address selection on the phone** (AP58 final step).
///
/// Until now the phone guarded only the engine half (`RepackagerTests`: a raw stream
/// gets the direct renderer), and the TV only the address half through its own
/// calls. Now both devices check both halves — `LiveModelTests` on the TV.
@Suite("Channel address on the phone")
struct ChannelAddressPhoneTests {

    static let channels = Channel(
        id: "2", name: "Das Nordlicht",
        streamURL: URL(string: "http://example.invalid:2086/live/user/pass/2.m3u8")!,
        playlistID: "test")

    @Test("An access without lists gets the raw stream")
    func accessWithoutLists() {
        let address = ProviderChannelSource.address(
            forItem: Self.channels, allowsHLS: false, store: InMemoryStore())
        #expect(address.pathExtension == "ts")
        let isAllowed = ProviderChannelSource.address(
            forItem: Self.channels, allowsHLS: true, store: InMemoryStore())
        #expect(isAllowed == Self.channels.streamURL)
    }

    /// The TV's note applies here too — same store, same rule.
    @Test("A remembered channel goes straight out as a raw stream")
    func rememberedChannel() {
        let store = InMemoryStore()
        var watchlist = RawStreamMemory.load(from: store)
        watchlist.remember(Self.channels.streamURL)
        watchlist.save(to: store)
        let address = ProviderChannelSource.address(
            forItem: Self.channels, allowsHLS: true, store: store)
        #expect(address.pathExtension == "ts")
    }
}
