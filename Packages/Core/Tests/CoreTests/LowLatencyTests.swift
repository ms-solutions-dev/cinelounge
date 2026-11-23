import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import Core

/// Turns the half-second test sample into a long channel: the same packets,
/// repeated several times in a row, with **advanced timestamps**.
///
/// **Why this is needed:** The test material is half a second long. A
/// running playlist that does not change makes AVFoundation abort after
/// one and a half target durations — so a playback test on the static sample would test
/// the length of the sample and not the code (see ``LiveRemuxSessionTests``).
/// A growing stream needs stamps that keep advancing; otherwise
/// ``StreamClock`` would take every pass for a jump back.
///
/// Only what ``StreamClock`` reads is written: PTS and DTS in the PES header.
/// Nobody reads the program clock in the adaptation field.
enum TSLooper {

    /// The stream, `copies` times in a row.
    static func loop(_ data: Data, copies: Int) -> Data {
        let span = duration(of: data)
        var out = Data()
        for copy in 0..<copies {
            out.append(shifted(data, by: UInt64(copy) * span))
        }
        return out
    }

    /// The length of one pass in 90 kHz ticks: from the smallest to the
    /// largest frame time, plus one frame spacing.
    static func duration(of data: Data) -> UInt64 {
        guard let video = TransportStream.inventory(from: data).video else { return 45_000 }
        let stamps = TransportStream.payloads(from: data, pid: video.pid).compactMap(\.pts).sorted()
        guard let first = stamps.first, let last = stamps.last, stamps.count > 1 else { return 45_000 }
        let gaps = zip(stamps.dropFirst(), stamps).map { $0 - $1 }.sorted()
        let frame = gaps[gaps.count / 2]
        return last - first + frame
    }

    /// The same packets with timestamps advanced by `offset`.
    static func shifted(_ data: Data, by offset: UInt64) -> Data {
        var out = data
        var index = 0
        while index + 188 <= out.count {
            defer { index += 188 }
            guard out[index] == 0x47 else { continue }
            let startsUnit = out[index + 1] & 0x40 != 0
            let control = (out[index + 3] >> 4) & 0x03
            var payload = index + 4
            if control & 0x02 != 0 { payload += 1 + Int(out[index + 4]) }
            guard startsUnit, control & 0x01 != 0, payload + 14 <= index + 188,
                out[payload] == 0, out[payload + 1] == 0, out[payload + 2] == 1
            else { continue }
            let flags = out[payload + 7]
            if flags & 0x80 != 0 { shift(&out, at: payload + 9, by: offset) }
            if flags & 0x40 != 0 { shift(&out, at: payload + 14, by: offset) }
        }
        return out
    }

    /// Reads a 33-bit stamp at `at`, adds, writes back — with
    /// the same marker bits the PES header requires.
    private static func shift(_ data: inout Data, at position: Int, by offset: UInt64) {
        guard position + 5 <= data.count else { return }
        let b0 = UInt64(data[position]), b1 = UInt64(data[position + 1])
        let b2 = UInt64(data[position + 2]), b3 = UInt64(data[position + 3])
        let b4 = UInt64(data[position + 4])
        let value =
            ((b0 >> 1) & 0x07) << 30 | (b1 << 22) | ((b2 >> 1) & 0x7F) << 15 | (b3 << 7)
            | ((b4 >> 1) & 0x7F)
        let moved = (value + offset) & 0x1_FFFF_FFFF
        let prefix = data[position] & 0xF0
        data[position] = prefix | UInt8((moved >> 30) & 0x07) << 1 | 1
        data[position + 1] = UInt8((moved >> 22) & 0xFF)
        data[position + 2] = UInt8((moved >> 15) & 0x7F) << 1 | 1
        data[position + 3] = UInt8((moved >> 7) & 0xFF)
        data[position + 4] = UInt8(moved & 0x7F) << 1 | 1
    }
}

/// The playlist with parts and the server that holds requests.
@Suite("Low-Latency HLS: parts and held requests")
struct LowLatencyTests {

    private func fixture() throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/hevc-live-long", withExtension: "ts"))
        return try Data(contentsOf: url)
    }

    @Test("The running list carries parts, the file does not")
    func liveListCarriesParts() {
        let pieces = (0..<8).map { RemuxPlaylist.Piece(duration: 0.5, independent: $0 % 4 == 0) }
        let live = RemuxPlaylist.build(
            pieces: pieces, firstIndex: 10, base: "http://h", parts: true, nextIndex: 18)
        #expect(live.contains("#EXT-X-VERSION:9"))
        #expect(live.contains("#EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=1.00000"))
        #expect(live.contains("#EXT-X-PART-INF:PART-TARGET=0.60000"))
        #expect(live.contains("#EXT-X-PART:DURATION=0.50000,URI=\"http://h/segment14.m4s\",INDEPENDENT=YES"))
        #expect(live.contains("#EXT-X-PART:DURATION=0.50000,URI=\"http://h/segment15.m4s\"\n"))
        #expect(live.contains("#EXT-X-PRELOAD-HINT:TYPE=PART,URI=\"http://h/segment18.m4s\""))
        // Parts only for the last six — the first two pieces without.
        #expect(!live.contains("URI=\"http://h/segment10.m4s\",INDEPENDENT"))
        #expect(live.contains("#EXTINF:0.50000,\nhttp://h/segment10.m4s"))
        // With parts no explicit start: The entry point comes from the hold-back.
        #expect(!live.contains("#EXT-X-START"))

        let file = RemuxPlaylist.build(
            pieces: pieces, isLive: false, base: "http://h", parts: true, nextIndex: 18)
        #expect(!file.contains("#EXT-X-PART"))
        #expect(!file.contains("PRELOAD-HINT"))
        #expect(file.contains("#EXT-X-ENDLIST"))
    }

    /// The system writer gets the list as it was; parts only exist once
    /// the remuxer allows them — see ``SegmentStore/allowParts()``.
    @Test("The download ledger enables parts only with the own writer")
    func storeEnablesPartsOnlyForDependentPieces() {
        let plain = SegmentStore()
        plain.setHeader(Data([0]))
        for _ in 0..<4 { plain.append(Data([0]), duration: 2) }
        #expect(!plain.playlist(base: "http://h").contains("EXT-X-PART"))

        let own = SegmentStore()
        // The part tests need the parts — they have been off since 2026-09-04.
        own.lowLatency = true
        own.allowParts()
        own.setHeader(Data([0]))
        own.append(Data([0]), duration: 0.5, independent: true)
        own.append(Data([0]), duration: 0.5, independent: false)
        let list = own.playlist(base: "http://h")
        #expect(list.contains("EXT-X-PART-INF"))
        #expect(list.contains("segment0.m4s\",INDEPENDENT=YES"))
        #expect(list.contains("PRELOAD-HINT:TYPE=PART,URI=\"http://h/segment2.m4s\""))
    }

    /// The window throws away whole groups of pictures at the front — the first piece always
    /// starts with a keyframe.
    @Test("The window always starts with a keyframe")
    func windowStartsAtKeyframe() {
        let store = SegmentStore()
        store.setHeader(Data([0]))
        // Groups of pictures of four pieces at half a second each; 100 pieces = 50 s.
        for index in 0..<100 {
            store.append(Data([UInt8(index)]), duration: 0.5, independent: index % 4 == 0)
        }
        #expect(store.seconds >= SegmentStore.windowSeconds - 2)
        #expect(store.seconds <= SegmentStore.windowSeconds + 0.6)
        let list = store.playlist(base: "http://h")
        let first = list.split(separator: "\n").first { $0.hasPrefix("#EXT-X-MEDIA-SEQUENCE") }
        let sequence = Int(first?.split(separator: ":").last ?? "") ?? -1
        #expect(sequence % 4 == 0, "first chunk \(sequence) is not a keyframe chunk")
    }

    @Test("Name and query parts are split")
    func splitsQuery() {
        let (name, query) = LocalMediaServer.split("media.m3u8?_HLS_msn=12&_HLS_part=0")
        #expect(name == "media.m3u8")
        #expect(query == ["_HLS_msn": "12", "_HLS_part": "0"])
        #expect(LocalMediaServer.split("segment3.m4s").query.isEmpty)
        #expect(RemuxStream.awaitedSegment(name: "media.m3u8", query: ["_HLS_msn": "12"]) == 12)
        #expect(RemuxStream.awaitedSegment(name: "media.m3u8", query: [:]) == nil)
        #expect(RemuxStream.awaitedSegment(name: "segment7.m4s", query: [:]) == 7)
        #expect(RemuxStream.awaitedSegment(name: "header.mp4", query: [:]) == nil)
    }

    /// **The server holds what is not there yet** — and delivers as soon as it is there.
    @Test("A request for a future chunk waits until it exists")
    func serverHoldsForFuturePiece() async throws {
        let store = SegmentStore()
        store.setHeader(Data([1, 2, 3]))
        store.append(Data([4]), duration: 0.5, independent: true)

        let stream = try RemuxStream(store: store, isLive: true)
        try await stream.start()
        defer { stream.stop() }

        // Piece 1 does not exist yet; it comes into being in 200 ms.
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            store.append(Data([5, 6]), duration: 0.5, independent: false)
        }
        let started = Date()
        let url = try #require(URL(string: "\(stream.base)/segment1.m4s"))
        let (bytes, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(bytes == Data([5, 6]))
        #expect(Date().timeIntervalSince(started) >= 0.15)

        // And the blocking list only arrives with piece 2.
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            store.append(Data([7]), duration: 0.5, independent: false)
        }
        let listURL = try #require(URL(string: "\(stream.base)/media.m3u8?_HLS_msn=2"))
        let (listing, _) = try await URLSession.shared.data(from: listURL)
        #expect(String(decoding: listing, as: UTF8.self).contains("segment2.m4s"))
    }

    /// What never comes is answered honestly after the deadline — not held forever.
    @Test("The deadline ends the hold")
    func holdGivesUp() async throws {
        let store = SegmentStore()
        store.setHeader(Data([1]))
        store.append(Data([4]), duration: 0.5)
        let stream = try RemuxStream(store: store, isLive: true)
        try await stream.start()
        defer { stream.stop() }

        let url = try #require(URL(string: "\(stream.base)/segment9.m4s"))
        let started = Date()
        let (_, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 404)
        #expect(Date().timeIntervalSince(started) >= RemuxStream.holdTimeout - 0.5)
    }
}

/// **The finding F-004:** A channel with jumping timestamps produced
/// pieces of 2.2 and 5.3 s, the list promised 0.6 — AVPlayer refused.
@Suite("Gaps in the stream and the part promise")
struct GapAndPartTargetTests {

    private func fixture() throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/hevc-live-long", withExtension: "ts"))
        return try Data(contentsOf: url)
    }

    /// A piece over the promise appears as a piece in the list, not as a part.
    @Test("A chunk that is too long is not a part")
    func longPieceIsNotAPart() {
        let store = SegmentStore()
        // The part tests need the parts — they have been off since 2026-09-04.
        store.lowLatency = true
        store.allowParts()
        store.setHeader(Data([0]))
        store.append(Data([1]), duration: 0.5, independent: true)
        store.append(Data([2]), duration: 2.2, independent: false)
        store.append(Data([3]), duration: 0.52, independent: false)
        let list = store.playlist(base: "http://h")

        #expect(list.contains("#EXT-X-PART:DURATION=0.50000,URI=\"http://h/segment0.m4s\""))
        #expect(!list.contains("URI=\"http://h/segment1.m4s\",") && !list.contains("DURATION=2.20000"))
        #expect(list.contains("#EXTINF:2.20000,\nhttp://h/segment1.m4s"))
        #expect(list.contains("#EXT-X-PART:DURATION=0.52000,URI=\"http://h/segment2.m4s\""))
        // The promise stays at 0.6 — the giant did not let it grow.
        #expect(list.contains("#EXT-X-PART-INF:PART-TARGET=0.60000"))
        // The target duration did, though: It must carry every piece.
        #expect(list.contains("#EXT-X-TARGETDURATION:3"))
    }

    /// If a piece grows just over the promise, the promise grows with it — and
    /// never shrinks again.
    @Test("The part promise grows along and never drops")
    func partTargetGrowsMonotonically() {
        let store = SegmentStore()
        // The part tests need the parts — they have been off since 2026-09-04.
        store.lowLatency = true
        store.allowParts()
        store.setHeader(Data([0]))
        store.append(Data([1]), duration: 0.5, independent: true)
        store.append(Data([2]), duration: 0.84, independent: false)
        #expect(store.playlist(base: "http://h").contains("PART-TARGET=0.84000"))
        #expect(store.playlist(base: "http://h").contains("DURATION=0.84000"))
        for _ in 0..<40 { store.append(Data([3]), duration: 0.5, independent: false) }
        #expect(store.playlist(base: "http://h").contains("PART-TARGET=0.84000"))
    }
}

/// The way back without parts — for channels where AVPlayer rejected the part
/// path (F-019).
@Suite("The list without part promise")
struct LowLatencyMemoryTests {
    @Test("A rejected channel is remembered, another one is not")
    func rejectionIsRemembered() {
        let memory = LowLatencyMemory()
        let a = URL(string: "http://p/live/u/p/1.ts")!
        let b = URL(string: "http://p/live/u/p/2.ts")!
        #expect(!memory.isRejected(a))
        memory.reject(a)
        #expect(memory.isRejected(a))
        #expect(!memory.isRejected(b))
    }

    @Test("A download ledger without part promise writes no parts and no blocking reload")
    func storeWithoutPartsWritesPlainList() throws {
        let store = SegmentStore()
        store.allowParts()
        store.lowLatency = false
        for i in 0..<4 {
            store.append(Data(repeating: UInt8(i), count: 100), duration: 0.5, independent: i % 2 == 0)
        }
        let list = store.playlist(base: "http://h")
        #expect(!list.contains("#EXT-X-PART"))
        #expect(!list.contains("CAN-BLOCK-RELOAD"))
        #expect(list.contains("#EXTINF:"))
    }
}
