import Core
import Foundation
import Testing

@testable import Flows

/// **The remuxer's fallback chain as a board** (AP58 R4, report A S3) — TV and phone have
/// followed it identically since; what becomes of it per device is checked by their
/// packages.
@Suite("Remuxer start")
struct RemuxerStartTests {

    static func target(
        _ kind: PlaybackTarget.Kind, deliveryRoute: Delivery = .remuxInApp, startAt: TimeInterval = 0
    ) -> PlaybackTarget {
        PlaybackTarget(
            itemID: kind == .live ? nil : "film", title: "T",
            url: URL(string: "http://server/datei.mkv")!,
            decision: PlaybackDecision(
                engine: .native, delivery: deliveryRoute, reason: .remuxedInApp, maxBitrate: 8_000_000,
                audioStreamIndex: 2),
            startAt: startAt, kind: kind)
    }

    struct Broken: Error {}

    @Test("Overtaken, rejection, server, last attempt")
    func chain() {
        #expect(
            RemuxStart.fallback(after: CancellationError(), target: Self.target(.live), sourceIsChunked: true)
                == .superseded)
        #expect(
            RemuxStart.fallback(
                after: LiveRemuxSession.SessionFailure.refused(status: 403), target: Self.target(.live),
                sourceIsChunked: false) == .rejection(status: 403))

        guard
            case .serverChunks(let chunked) = RemuxStart.fallback(
                after: Broken(), target: Self.target(.recording), sourceIsChunked: true)
        else {
            Issue.record("a file with a media server is chunked")
            return
        }
        #expect(chunked.delivery == .hls)
        #expect(chunked.engine == .native)
        #expect(chunked.maxBitrate == 8_000_000, "the limits travel along")
        #expect(chunked.audioStreamIndex == 2, "the audio track too")

        for (kind, isChunked) in [(PlaybackTarget.Kind.recording, false), (.live, true)] {
            guard
                case .lastAttempt(let raw) = RemuxStart.fallback(
                    after: Broken(), target: Self.target(kind), sourceIsChunked: isChunked)
            else {
                Issue.record("\(kind): no last attempt")
                continue
            }
            #expect(raw.delivery == .directPlay)
            #expect(raw.engine == .native)
            #expect(raw.reason == .containerNotNativelySupported)
        }
    }

    @Test(
        "A start position beyond the end of the file",
        arguments: [
            (1_200.0, 3_600.0, false), (3_596, 3_600, true), (3_595, 3_600, true),
            (3_594, 3_600, false), (0.5, 3, false), (100, 0, false),
        ])
    func tooShort(startAt: TimeInterval, duration: TimeInterval, expected: Bool) {
        #expect(RemuxStart.tooShort(startAt: startAt, duration: duration) == expected)
    }

    @Test("The start mark needs server chunking, a recording and a position")
    func startMark() {
        #expect(RemuxStart.needsStartMark(Self.target(.recording, deliveryRoute: .hls, startAt: 600)))
        #expect(!RemuxStart.needsStartMark(Self.target(.recording, deliveryRoute: .hls, startAt: 1)))
        #expect(!RemuxStart.needsStartMark(Self.target(.recording, startAt: 600)))
        #expect(!RemuxStart.needsStartMark(Self.target(.live, deliveryRoute: .hls, startAt: 600)))
    }

    @Test("The hint of a truncated file is in the shared catalog")
    func hint() {
        #expect(RemuxStart.clockTime(3_725) == "1:02:05")
        #expect(!AppLanguageSetting.word("player.truncatedFile").hasPrefix("player."))
    }
}
