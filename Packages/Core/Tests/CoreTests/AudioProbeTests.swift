import AVFAudio
import CoreMedia
import Foundation
import Testing

@testable import Core

/// The audio probe: runs a TS recording through the same repackager as the
/// direct renderer and measures the sound that comes out — frame building in the
/// raw stream, timeline of the finished packets, and for Layer II our own
/// decoder against Apple's. Runs only with `PROBE_TS=<Pfad>`.
///
/// **Why it exists** (2026-09-07, "an occasional noise" on Telve 1 on the
/// phone): the report saw timestamps, lead and pump pauses — but
/// not the sound itself. Without this probe it was impossible to say whether the noise
/// is in the data or only arises in the device's audio output. With it
/// it was settled in a minute: 170 s of Telve 1 HQ, 0 gaps, 0
/// re-anchorings, 0 noise-like blocks — the data is clean.
struct AudioProbeTests {

    @Test("Audio probe") func probe() async throws {
        guard let path = ProcessInfo.processInfo.environment["PROBE_TS"] else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        print("PROBE Recording: \(data.count / 1_000_000) MB")

        // ── Raw stream: frames per PES, cut frames, foreign headers ──
        let reader = TransportStreamReader()
        var pieces: [TransportStreamReader.Piece] = []
        var offset = 0
        while offset < data.count {
            let end = min(offset + 65536, data.count)
            pieces += reader.read(data.subdata(in: offset..<end))
            offset = end
        }
        pieces += reader.flush()
        let audioPieces = pieces.filter { $0.kind == .aac || $0.kind == .mp2Audio }
        var mp2Frames: [Data] = []
        var remainders = 0
        var foreign = 0
        var histogram: [Int: Int] = [:]
        var firstHeader: AudioAssembly.ADTSHeader?
        var firstMP2: MPEGAudio.FrameInfo?
        for p in audioPieces {
            var sum = 0
            var n = 0
            if p.kind == .aac {
                let f = AudioAssembly.frames(in: p.data)
                n = f.count
                for x in f {
                    sum += x.header.frameLength
                    if firstHeader == nil { firstHeader = x.header }
                    if let k = firstHeader,
                        k.sampleRateIndex != x.header.sampleRateIndex
                            || k.channelConfiguration != x.header.channelConfiguration
                    {
                        foreign += 1
                    }
                }
            } else {
                let f = MPEGAudio.frames(in: p.data)
                n = f.count
                for x in f {
                    mp2Frames.append(x)
                    sum += x.count
                    let i = MPEGAudio.info(in: x)
                    if firstMP2 == nil { firstMP2 = i }
                    if let a = firstMP2, let i, a != i { foreign += 1 }
                }
            }
            histogram[n, default: 0] += 1
            if sum != p.data.count { remainders += 1 }
        }
        print(
            "PROBE audio PES: \(audioPieces.count), frames per PES: "
                + histogram.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }
                .joined(separator: " ")
                + ", cut: \(remainders), foreign headers: \(foreign)")
        #expect(foreign == 0, "a foreign header is a false sync — the decoder would get garbage")

        // ── The repackager as in the direct renderer ──
        let queue = SampleQueue(label: "sonde")
        let remuxer = TransportRemuxer(sink: queue)
        var audio: [CMSampleBuffer] = []
        func fetch() {
            while queue.nextVideo() != nil {}
            while let a = queue.nextAudio() { audio.append(a) }
        }
        offset = 0
        while offset < data.count {
            let end = min(offset + 65536, data.count)
            remuxer.feed(data.subdata(in: offset..<end))
            fetch()
            offset = end
        }
        await remuxer.finish()
        fetch()
        try #require(!audio.isEmpty, "the remuxer delivered no audio")

        var gaps = 0
        var overlaps = 0
        var largest = 0.0
        var previous: CMSampleBuffer?
        for a in audio {
            if let v = previous {
                let d = (a.presentationTimeStamp - (v.presentationTimeStamp + v.duration)).seconds
                if d > 0.001 { gaps += 1; largest = max(largest, d) }
                if d < -0.001 { overlaps += 1 }
            }
            previous = a
        }
        let span =
            (audio.last!.presentationTimeStamp - audio[0].presentationTimeStamp).seconds
            + audio.last!.duration.seconds
        print(
            String(
                format:
                    "PROBE remuxer: %d audio packets, %.3f s, gaps %d (largest %.0f ms), overlaps %d, re-anchors %d",
                audio.count, span, gaps, largest * 1000, overlaps,
                remuxer.audioReanchors))
        #expect(gaps == 0, "a gap in the audio axis is an audible dropout")
        #expect(overlaps == 0)

        // ── Layer II: our own decoder against Apple's ──
        // On the Mac Apple's decoder exists; on the device it does not. A frame for which
        // our own delivers more than two and a half times the level of Apple's
        // is a noise burst — exactly what one heard on the device and did not see here.
        guard let info = firstMP2, !mp2Frames.isEmpty else { return }
        var own = MP2Decoder()
        let mp2Format = AVAudioFormat(cmAudioFormatDescription: try MPEGAudio.formatDescription(for: info))
        let pcmFormat = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: Double(info.sampleRate), channels: 2,
                interleaved: false))
        guard let apple = AVAudioConverter(from: mp2Format, to: pcmFormat) else { return }
        var conspicuous = 0
        var sumOwn: Float = 0
        var sumApple: Float = 0
        for frame in mp2Frames {
            guard let mine = own.decode(frame) else { continue }
            var sq: Float = 0
            for j in stride(from: 0, to: mine.count, by: 2) {
                let f = Float(mine[j]) / 32768
                sq += f * f
            }
            let rmsOwn = (sq / 1152).squareRoot()
            let cb = AVAudioCompressedBuffer(
                format: mp2Format, packetCapacity: 1, maximumPacketSize: frame.count)
            frame.withUnsafeBytes { cb.data.copyMemory(from: $0.baseAddress!, byteCount: frame.count) }
            cb.byteLength = UInt32(frame.count)
            cb.packetCount = 1
            cb.packetDescriptions?.pointee = AudioStreamPacketDescription(
                mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(frame.count))
            let out = try #require(AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 2304))
            nonisolated(unsafe) let once = cb
            let state = Feeder()
            var error: NSError?
            let status = apple.convert(to: out, error: &error) { _, s in
                if state.fed { s.pointee = .noDataNow; return nil }
                state.fed = true
                s.pointee = .haveData
                return once
            }
            var rmsApple: Float = 0
            if status != .error, out.frameLength > 0, let ch = out.floatChannelData {
                var q: Float = 0
                for j in 0..<Int(out.frameLength) { q += ch[0][j] * ch[0][j] }
                rmsApple = (q / Float(out.frameLength)).squareRoot()
            }
            sumOwn += rmsOwn
            sumApple += rmsApple
            if rmsOwn > 0.02, rmsOwn > rmsApple * 2.5 { conspicuous += 1 }
        }
        print(
            String(
                format: "PROBE Layer II: %d frames, own level %.4f vs Apple %.4f, noise bursts %d",
                mp2Frames.count, sumOwn / Float(mp2Frames.count), sumApple / Float(mp2Frames.count),
                conspicuous))
        #expect(conspicuous == 0, "our own decoder delivers frames that Apple's does not")
    }

    /// Same pattern as in `MPEGAudioTranscoder`: the input block is `@Sendable`,
    /// but is called synchronously — a class field instead of a captured variable.
    private final class Feeder: @unchecked Sendable {
        var fed = false
    }
}
