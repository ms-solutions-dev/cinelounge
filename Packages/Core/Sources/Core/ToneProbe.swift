import AudioToolbox
import CoreMedia
import Foundation

/// The remote-controlled audio probe: does the MPEG audio path work **on this
/// device**?
///
/// **The reason it exists is a fallacy of 2026-08-16:** the MP2 proof of concept
/// was confirmed on the Mac (`afconvert` converts, the probe decodes) — and on
/// the Apple TV the channels stayed silent anyway. What a Mac decoder can do
/// says nothing about what tvOS ships. This probe puts the question to the
/// device itself: three real frames from the Telve-1 recording through the full
/// chain, finding into the log.
///
/// Requested like the sidebar probe via the environment:
/// `CINELOUNGE_PROBE=audio` — on the device via
/// `devicectl device process launch --environment-variables …`.
public enum ToneProbe {

    /// Whether the probe was requested.
    public static var isRequested: Bool {
        ProcessInfo.processInfo.environment["CINELOUNGE_PROBE"] == "ton"
    }

    /// Three whole frames from the Telve-1-HQ recording: MPEG-1 Layer II, 256
    /// kbit/s, 48 kHz, stereo.
    static let capturedFrames = Data(
        base64Encoded:
            "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"
    )!

    /// Runs the probe and writes the finding into the log.
    public static func run() {
        guard let info = MPEGAudio.info(in: capturedFrames) else {
            Diagnostics.playbackProblem("Audio probe: the frame header is not read", since: nil)
            return
        }
        Diagnostics.playbackStep(
            "Audio probe: frame recognised — layer \(info.layer), \(info.sampleRate) Hz, "
                + "\(info.channels) channels",
            since: nil
        )
        // **First the catalog, then the attempt.** A failed attempt says THAT it
        // does not work; the lists say WHAT is missing — and they answer even when
        // the attempt fails for a third reason.
        reportCodecInventory()

        let transcoder: MPEGAudioTranscoder
        do {
            transcoder = try MPEGAudioTranscoder(checking: info)
        } catch {
            let reason =
                (error as? MPEGAudioTranscoder.Obstacle)?.rawValue ?? String(describing: error)
            Diagnostics.playbackProblem(
                "Audio probe: setup failed — \(reason)",
                since: nil
            )
            return
        }
        var packets = 0
        var bytes = 0
        for (index, frame) in MPEGAudio.frames(in: capturedFrames).enumerated() {
            let time = CMTime(
                value: CMTimeValue(index * info.samplesPerFrame),
                timescale: CMTimeScale(info.sampleRate))
            for packet in transcoder.transcode(frame, at: time) {
                packets += 1
                bytes += packet.payload.count
            }
        }
        if packets == 0 {
            Diagnostics.playbackProblem(
                "Audio probe: transcoder is up but delivers NOTHING — 3 frames in, 0 packets out",
                since: nil
            )
        } else {
            Diagnostics.playbackStep(
                "Audio probe: \(packets) AAC packets (\(bytes) bytes) from 3 frames — the path holds",
                since: nil
            )
        }
    }

    /// Asks the device which formats it can decode and encode.
    ///
    /// **The question the diagnosis of 2026-08-22 left open.** There it said "no
    /// transcoder" six times, and from that it was not possible to tell whether
    /// tvOS lacks the MP2 decoder or the AAC encoder — two findings with
    /// completely different ways out. `AudioFormatGetProperty` answers both
    /// directly and without the detour of an attempt.
    static func reportCodecInventory() {
        let decoders = formatIDs(kAudioFormatProperty_DecodeFormatIDs)
        let encoders = formatIDs(kAudioFormatProperty_EncodeFormatIDs)

        // Only the formats that matter here — the full lists are long and illegible
        // on a TV.
        let relevant: [(String, AudioFormatID)] = [
            ("MP1", kAudioFormatMPEGLayer1),
            ("MP2", kAudioFormatMPEGLayer2),
            ("MP3", kAudioFormatMPEGLayer3),
            ("AAC", kAudioFormatMPEG4AAC),
            ("AC-3", kAudioFormatAC3),
            ("PCM", kAudioFormatLinearPCM),
        ]
        let decodes = relevant.filter { decoders.contains($0.1) }.map(\.0)
        let encodes = relevant.filter { encoders.contains($0.1) }.map(\.0)

        Diagnostics.playbackStep(
            "Audio probe: this device DECODES "
                + (decodes.isEmpty ? "none of them" : decodes.joined(separator: ", "))
                + " · ENCODES "
                + (encodes.isEmpty ? "none of them" : encodes.joined(separator: ", "))
                + " (of \(decoders.count) decoders and \(encoders.count) encoders in total)",
            since: nil
        )
    }

    /// The format list behind a property of `AudioFormat`.
    ///
    /// Two-step, as AudioToolbox demands: first ask for the size, then fill the
    /// buffer. An error returns the empty list — and the evaluation above then
    /// says "none of it", which is honest.
    private static func formatIDs(_ property: AudioFormatPropertyID) -> Set<AudioFormatID> {
        var size: UInt32 = 0
        guard AudioFormatGetPropertyInfo(property, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        var ids = [AudioFormatID](repeating: 0, count: Int(size) / MemoryLayout<AudioFormatID>.size)
        guard AudioFormatGetProperty(property, 0, nil, &size, &ids) == noErr else { return [] }
        return Set(ids)
    }
}
