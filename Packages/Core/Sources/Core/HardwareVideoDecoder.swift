import CoreMedia
import Foundation
import VideoToolbox

/// Decodes pictures itself — in the same hardware, but with its own rules.
///
/// **Why, if the layer can do that itself:** `AVSampleBufferDisplayLayer`
/// decodes compressed packets on its own, and for the normal case that is the
/// right way. But it cannot be told anything. The `VTDecompressionSession`
/// behind it knows properties that only whoever builds it themselves gets —
/// and one of them is the answer to E25: **`FieldMode = DeinterlaceFields`**.
/// All German and Turkish 1080i channels deliver fields; the
/// system player shows them interlaced, VLC deinterlaces in software (`yadif`).
/// Here the hardware deinterlaces, and the finished picture goes into the layer.
///
/// **What runs differently here than when passing through:** The hardware delivers
/// asynchronously and in decode order. With B-pictures that is not the
/// presentation order — so a small reorder buffer holds back the last pictures
/// and releases them by presentation time. Four pictures of depth are enough
/// for every group of pictures a channel sends.
///
/// **Only where it brings something.** The own decoder is built only for
/// streams with fields (``isWorthwhile(for:)``); progressive channels keep
/// going through the layer — there is nothing there the hardware should do
/// differently, and every detour costs.
public final class HardwareVideoDecoder: @unchecked Sendable {

    /// How many pictures are held back for reordering.
    public static let reorderDepth = 4
    /// How many pictures may be in the decoder at the same time at most.
    public static let maxInFlight = 12

    private let lock = NSLock()
    private var session: VTDecompressionSession?
    private var format: CMFormatDescription?
    private var reorder: [(time: CMTime, sample: CMSampleBuffer)] = []
    private var inFlight = 0
    private var _decoded = 0
    private var _failed = 0
    private var _deinterlacing = false
    private var reportedFailure = false
    private let output: @Sendable (CMSampleBuffer) -> Void

    /// - Parameter output: Bekommt jedes fertige Bild in Darstellungsfolge.
    public init(output: @escaping @Sendable (CMSampleBuffer) -> Void) {
        self.output = output
    }

    deinit { invalidate() }

    // MARK: - Auskunft

    /// Whether this stream carries fields — the flag that
    /// ``SampleAssembly/withFields(_:)`` writes into the description.
    public static func isInterlaced(_ format: CMFormatDescription) -> Bool {
        (CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_FieldCount)
            as? Int) == 2
    }

    /// Whether the own decoder is touched at all.
    ///
    /// **Off, since the first on-device test** (F-016, 2026-09-03): The Apple TV
    /// rejects `FieldMode = DeinterlaceFields` (`-12900`,
    /// `kVTPropertyNotSupportedErr`) — so the own decoder brought no
    /// deinterlacing, but for "DE: Rendal HQ" 1699 decoder errors: A rejected
    /// picture (`-12911`) fell, still compressed, into a renderer that expected
    /// finished pictures. The path stays built — for a device that accepts the property,
    /// or for a software decoder in front of it (MPEG-2, AP6) —, but it
    /// is only switched on again when it has something to offer.
    public nonisolated(unsafe) static var enabled = false

    static let storageKey = "live.ownDecoder"

    /// Loads the switch at app start — the same lesson as with
    /// ``DebugMode/activate(from:)``: A setting that does not survive its
    /// restart is none.
    public static func activate(from store: any KeyValueStore) {
        enabled = (try? store.value(for: storageKey)) == "1"
    }

    public static func save(_ on: Bool, to store: any KeyValueStore) {
        enabled = on
        if on {
            try? store.set("1", for: storageKey)
        } else {
            try? store.remove(storageKey)
        }
    }

    /// Whether the own decoder is worthwhile for this stream.
    public static func isWorthwhile(for format: CMFormatDescription) -> Bool {
        enabled && isInterlaced(format)
    }

    /// Whether the hardware accepted the deinterlacing.
    public var isDeinterlacing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _deinterlacing
    }

    /// How many pictures came out finished.
    public var decodedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _decoded
    }

    /// How many pictures the decoder rejected.
    public var failedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _failed
    }

    /// How many pictures are still in flight — in the decoder or in the reorder buffer.
    public var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return inFlight + reorder.count
    }

    // MARK: - Dekodieren

    /// Hands a compressed picture to the hardware. `false` if no decoder
    /// could be created — then the caller should pass the packet through.
    @discardableResult
    public func decode(_ sample: CMSampleBuffer) -> Bool {
        guard let description = sample.formatDescription else { return false }
        lock.lock()
        var setup: Setup?
        if session == nil
            || format.map({ !CMFormatDescriptionEqual($0, otherFormatDescription: description) }) ?? true
        {
            setup = prepare(for: description)
        }
        let session = self.session
        if session != nil { inFlight += 1 }
        lock.unlock()

        // **Report outside the lock** — the report takes it itself, and
        // taken a second time the thread would stand forever. And nothing
        // foreign under a held lock, not even a trace line.
        if let hint = setup?.hint { Diagnostics.playbackStep(hint, since: nil) }
        if let error = setup?.error { reportFailure("Decoder not set up (\(error))") }
        guard let session else { return false }

        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample,
            flags: [._EnableAsynchronousDecompression, ._EnableTemporalProcessing],
            infoFlagsOut: nil
        ) { [weak self] status, _, imageBuffer, presentation, duration in
            self?.received(status: status, image: imageBuffer, at: presentation, duration: duration)
        }
        if status != noErr {
            lock.lock()
            inFlight -= 1
            _failed += 1
            lock.unlock()
            reportFailure("Frame rejected (\(status))")
            return false
        }
        return true
    }

    /// Waits for everything in flight and releases it — before a jump, at a stop.
    public func flush() {
        lock.lock()
        let session = session
        lock.unlock()
        if let session { VTDecompressionSessionWaitForAsynchronousFrames(session) }
        lock.lock()
        let rest = reorder.sorted { $0.time < $1.time }
        reorder.removeAll()
        lock.unlock()
        for entry in rest { output(entry.sample) }
    }

    /// Baut den Decoder ab. Danach beginnt ``decode(_:)`` von vorn.
    public func invalidate() {
        lock.lock()
        let old = session
        session = nil
        format = nil
        reorder.removeAll()
        inFlight = 0
        lock.unlock()
        if let old { VTDecompressionSessionInvalidate(old) }
    }

    // MARK: - Innen

    /// What the setup yielded — for reporting after releasing the lock.
    private struct Setup {
        var error: OSStatus?
        var hint: String?
    }

    /// To be called under the lock — and therefore without a report of its own.
    private func prepare(for description: CMFormatDescription) -> Setup {
        if let old = session { VTDecompressionSessionInvalidate(old) }
        session = nil
        format = nil

        var incoming: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: description,
            decoderSpecification: nil,
            imageBufferAttributes: nil,
            outputCallback: nil,
            decompressionSessionOut: &incoming)
        guard status == noErr, let incoming else { return Setup(error: status == noErr ? -1 : status) }
        session = incoming
        format = description

        // **The deinterlacing** — only with fields, and what the hardware
        // says about it is in the trace. On the Mac it rejects it; on the
        // Apple TV the device decides, and that is exactly what is to be measured.
        _deinterlacing = false
        if Self.isInterlaced(description) {
            let fieldMode = VTSessionSetProperty(
                incoming, key: kVTDecompressionPropertyKey_FieldMode,
                value: kVTDecompressionProperty_FieldMode_DeinterlaceFields)
            let deinterlace = VTSessionSetProperty(
                incoming, key: kVTDecompressionPropertyKey_DeinterlaceMode,
                value: kVTDecompressionProperty_DeinterlaceMode_Temporal)
            _deinterlacing = fieldMode == noErr
            return Setup(
                hint: _deinterlacing
                    ? "Deinterlacing: hardware accepts fields"
                        + (deinterlace == noErr ? ", temporal" : ", simple (\(deinterlace))")
                    : "Deinterlacing: hardware refuses (\(fieldMode)) — frames pass through interlaced")
        }
        return Setup()
    }

    private func received(status: OSStatus, image: CVImageBuffer?, at time: CMTime, duration: CMTime) {
        lock.lock()
        inFlight = max(0, inFlight - 1)
        guard status == noErr, let image else {
            _failed += 1
            lock.unlock()
            if status != noErr { reportFailure("Frame not decoded (\(status))") }
            return
        }
        guard let sample = Self.sample(from: image, at: time, duration: duration) else {
            _failed += 1
            lock.unlock()
            return
        }
        _decoded += 1
        reorder.append((time, sample))
        reorder.sort { $0.time < $1.time }
        var ready: [CMSampleBuffer] = []
        while reorder.count > Self.reorderDepth {
            ready.append(reorder.removeFirst().sample)
        }
        lock.unlock()
        for done in ready { output(done) }
    }

    /// A finished picture as a packet, the way the layer takes it.
    static func sample(from image: CVImageBuffer, at time: CMTime, duration: CMTime) -> CMSampleBuffer? {
        var description: CMVideoFormatDescription?
        guard
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: image,
                formatDescriptionOut: &description) == noErr, let description
        else { return nil }
        var timing = CMSampleTimingInfo(
            duration: duration, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard
            CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: image,
                formatDescription: description, sampleTiming: &timing,
                sampleBufferOut: &sample) == noErr
        else { return nil }
        return sample
    }

    /// Once per decoder, not per picture — otherwise a dying channel would fill
    /// the trace with fifty lines per second.
    private func reportFailure(_ reason: String) {
        lock.lock()
        let report = !reportedFailure
        reportedFailure = true
        lock.unlock()
        guard report else { return }
        Diagnostics.playbackProblem("Own decoder: \(reason)", since: nil)
    }
}
