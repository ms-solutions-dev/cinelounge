import Foundation
import Testing

@testable import Core

/// **Address and path of a channel, for both devices** (AP58 R4, report A S4).
@Suite("Channel address choice")
struct ChannelAddressChoiceTests {

    static let list = URL(string: "http://provider/live/u/p/4711.m3u8")!
    static let raw = URL(string: "http://provider/live/u/p/4711.ts")!

    @Test("A playlist stays a playlist as long as nothing speaks against it")
    func listStays() {
        #expect(
            ChannelAddressChoice.address(forItem: Self.list, name: "AHORN", store: InMemoryStore())
                == Self.list)
        #expect(
            ChannelAddressChoice.address(forItem: Self.raw, name: "AHORN", store: InMemoryStore())
                == Self.raw)
    }

    @Test("Access, memo and rule each lead to the raw stream")
    func rawReasons() {
        #expect(
            ChannelAddressChoice.address(
                forItem: Self.list, name: "AHORN", allowsHLS: false, store: InMemoryStore())
                == Self.raw)

        let remembered = InMemoryStore()
        var watchlist = RawStreamMemory.load(from: remembered)
        watchlist.remember(Self.list)
        watchlist.save(to: remembered)
        #expect(
            ChannelAddressChoice.address(forItem: Self.list, name: "AHORN", store: remembered) == Self.raw)

        let learned = InMemoryStore()
        var rule = RawStreamRule.load(from: learned)
        let pair = RawStreamRule.pair(counterpart: "provider", name: "AHORN")
        for _ in 0..<5 { rule.rememberRaw(pair) }
        rule.save(to: learned)
        #expect(rule.saysRaw(pair), "precondition: the rule says raw")
        #expect(ChannelAddressChoice.address(forItem: Self.list, name: "AHORN", store: learned) == Self.raw)
    }

    @Test("A raw stream is remuxed — via playlist or direct renderer, depending on the engine")
    func route() {
        let list = ChannelAddressChoice.decision(forItem: Self.raw, canDecodeHEVC: true, motor: .hls)
        #expect(list.delivery == .remuxInApp)
        let direct = ChannelAddressChoice.decision(forItem: Self.raw, canDecodeHEVC: true, motor: .renderer)
        #expect(direct.delivery == .renderInApp)
        #expect(
            !ChannelAddressChoice.decision(forItem: Self.list, canDecodeHEVC: true, motor: .renderer)
                .runsOverRepacker, "a provider playlist plays directly")
        #expect(
            !ChannelAddressChoice.decision(forItem: Self.raw, canDecodeHEVC: false, motor: .hls)
                .runsOverRepacker, "without HEVC no remuxer")
    }
}
