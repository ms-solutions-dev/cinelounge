import Foundation
import Testing

@testable import Core

/// **The image of the spot where playback continues** (2026-10-01).
@Suite("Still frame store")
struct StillFrameStoreTests {

    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "still-frames-\(UUID().uuidString)")
    }

    @Test("Stored, found — and a new image replaces the old one under a new address")
    func storeAndFind() throws {
        let bucket = folder()
        #expect(StillFrameStore.address(forItem: "titel-1", profile: nil, in: bucket) == nil)
        StillFrameStore.create(Data([0xFF, 0xD8, 0xFF]), forItem: "titel-1", profile: nil, in: bucket)
        let address = try #require(StillFrameStore.address(forItem: "titel-1", profile: nil, in: bucket))
        #expect(address.isFileURL)
        // A new image has a new address, the old one is dropped.
        Thread.sleep(forTimeInterval: 0.01)
        StillFrameStore.create(Data([0xFF, 0xD8, 0xFF]), forItem: "titel-1", profile: nil, in: bucket)
        let second = try #require(StillFrameStore.address(forItem: "titel-1", profile: nil, in: bucket))
        #expect(second != address)
        #expect(StillFrameStore.files("titel-1", profile: nil, in: bucket).count == 1)
        #expect(try Data(contentsOf: second) == Data([0xFF, 0xD8, 0xFF]))
        #expect(StillFrameStore.address(forItem: "titel-2", profile: nil, in: bucket) == nil)
    }

    @Test("Over the limit the oldest goes")
    func clear() throws {
        let bucket = folder()
        StillFrameStore.create(Data(count: 1000), forItem: "old", profile: nil, in: bucket)
        Thread.sleep(forTimeInterval: 1.1)
        StillFrameStore.create(Data(count: 1000), forItem: "new", profile: nil, in: bucket)
        StillFrameStore.cleanUp(in: bucket, limit: 1500)
        #expect(StillFrameStore.address(forItem: "old", profile: nil, in: bucket) == nil)
        #expect(StillFrameStore.address(forItem: "new", profile: nil, in: bucket) != nil)
    }

    @Test("Each profile has its own still frame")
    func perProfile() {
        let bucket = folder()
        StillFrameStore.create(Data([1]), forItem: "titel", profile: "profile-a", in: bucket)
        #expect(StillFrameStore.address(forItem: "titel", profile: "profile-a", in: bucket) != nil)
        #expect(StillFrameStore.address(forItem: "titel", profile: "profile-b", in: bucket) == nil)
    }
}
