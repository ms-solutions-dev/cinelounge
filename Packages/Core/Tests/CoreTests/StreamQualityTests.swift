import Foundation
import Testing

@testable import Core

/// This setting is the difference between a movie that plays on the go
/// and one that buffers endlessly. It must persist beyond an app launch —
/// whoever sets it on the train and finds it unlimited again on the next open
/// takes the app for broken.
@Suite("Bandwidth limit")
struct StreamQualityTests {

    @Test("A set limit survives saving and loading")
    func roundTrip() {
        let store = InMemoryStore()

        for quality in StreamQuality.allCases where quality != .unlimited {
            quality.save(to: store)
            #expect(StreamQuality.load(from: store) == quality)
        }
    }

    @Test("Unlimited deletes the entry instead of storing it")
    func unlimitedRemovesEntry() {
        // Otherwise an entry with the value "unlimited" would stay behind. By itself it would be
        // harmless, but the default could never be changed later without
        // overriding all viewers who never set anything.
        let store = InMemoryStore()
        StreamQuality.low.save(to: store)

        StreamQuality.unlimited.save(to: store)

        #expect((try? store.value(for: StreamQuality.storageKey)) == nil)
        #expect(StreamQuality.load(from: store) == .unlimited)
    }

    @Test("Without an entry, unlimited applies")
    func defaultsToUnlimited() {
        // One starts on the home network, and there every limit is a loss.
        #expect(StreamQuality.load(from: InMemoryStore()) == .unlimited)
    }

    @Test("An unreadable entry falls back to unlimited")
    func brokenEntry() {
        // Occurs after a rename or a step back to an older
        // version. Without a fallback this would be a crash at launch.
        let store = InMemoryStore()
        try? store.set("ultra", for: StreamQuality.storageKey)

        #expect(StreamQuality.load(from: store) == .unlimited)
    }

    @Test("Unlimited carries neither rate nor width")
    func unlimitedHasNoValues() {
        // These two values land unchanged in the request to the server. A
        // value instead of nothing would make it convert even on the home network.
        #expect(StreamQuality.unlimited.bitrate == nil)
        #expect(StreamQuality.unlimited.maxWidth == nil)
    }

    @Test("Every limited tier carries rate and width")
    func limitedStagesAreComplete() {
        // A rate without a width squeezes 4K into two Mbit/s — the picture then consists
        // of blocks, although fewer pixels would look markedly better.
        for quality in StreamQuality.allCases where quality != .unlimited {
            #expect(quality.bitrate != nil, "\(quality.rawValue) without rate")
            #expect(quality.maxWidth != nil, "\(quality.rawValue) without width")
        }
    }

    @Test("The tiers are ordered descending")
    func stagesAreOrdered() {
        // The order of allCases is the order in the settings menu.
        // If a higher level stood below a lower one, the viewer picks
        // the opposite of what they want — and notices only when buffering.
        let limited = StreamQuality.allCases.filter { $0 != .unlimited }

        for (higher, lower) in zip(limited, limited.dropFirst()) {
            guard let higherRate = higher.bitrate, let lowerRate = lower.bitrate,
                let higherWidth = higher.maxWidth, let lowerWidth = lower.maxWidth
            else {
                Issue.record("\(higher.rawValue) or \(lower.rawValue) is incomplete")
                continue
            }
            #expect(higherRate > lowerRate)
            #expect(higherWidth >= lowerWidth)
        }
    }

    @Test("The identifiers are fixed because they live in the store")
    func rawValuesAreStable() {
        // A rename silently resets the setting for every viewer
        // to unlimited — and then it buffers on the go again.
        #expect(StreamQuality.veryHigh.rawValue == "veryHigh")
        #expect(StreamQuality.high.rawValue == "high")
        #expect(StreamQuality.medium.rawValue == "medium")
        #expect(StreamQuality.low.rawValue == "low")
        #expect(StreamQuality.minimal.rawValue == "minimal")
        #expect(StreamQuality.storageKey == "playback.quality")
    }

    @Test("The lowest tier fits through the tunnel")
    func minimalFitsThroughTheTunnel() {
        // 0.3 Mbit/s were measured through the tunnel. Even the lowest level
        // is above that — it is the lower bound of the sensible, not a
        // guarantee. The value is here so that a later raise gets noticed.
        #expect(StreamQuality.minimal.bitrate == 500_000)
    }
}
