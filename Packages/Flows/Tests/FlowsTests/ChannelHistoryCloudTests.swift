import Testing

@testable import Flows
@testable import ProfileKit

/// The channel history travels via ``ProfileKit/DocumentPreference`` — **the same store key.**
@Suite("Channel history and document preference share the key")
struct ChannelHistoryCloudTests {
    @Test("Same key, same length")
    func equal() {
        #expect(DocumentPreference.slots[DocumentPreference.channelHistory] == ChannelHistory.key)
        #expect(DocumentPreference.historyLength == ChannelHistory.length)
    }
}
