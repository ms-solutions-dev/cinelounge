import CoreMedia

/// The continuous audio axis of a stream: frames follow each other without
/// gaps.
///
/// **The finding of 2026-09-04. (TELE MOOS, SELA 1, Varo):** every PES packet carries
/// its own timestamp, and the remuxer set every frame to the time of its
/// packet. If the channel rounds its marks (Varo: ±1 ms from packet to
/// packet), notches arise; if a frame is missing, a gap yawns — and the own
/// writer (``CMAFWriter``) writes both one to one into the time axis, where
/// the system writer had silently stretched the predecessor's duration. At
/// the live edge every notch is a stutter: the sound leads the clock, and
/// where it has a hole, the player waits for the next segment.
///
/// The rule: **the count of frames determines the time**, as long as the
/// packet time deviates from it by no more than half a frame forward or one
/// whole frame backward. If it deviates more, the stream really has a jump
/// (switch at the provider, frame lost at the source), and then the packet
/// time applies — ``StreamClock`` has already smoothed it.
struct AudioAxis: Sendable {
    private var next: CMTime?

    /// The time of the first frame of a packet.
    mutating func start(packetTime: CMTime, frameDuration: CMTime) -> CMTime {
        guard let next else { return packetTime }
        let deviation = (packetTime - next).seconds
        let frame = frameDuration.seconds
        guard deviation.isFinite, frame > 0 else { return packetTime }
        if deviation > -frame, deviation < frame / 2 { return next }
        return packetTime
    }

    /// After the last frame of a packet: where the next one would have to begin.
    mutating func next(after last: CMTime, frameDuration: CMTime) {
        next = last + frameDuration
    }

    mutating func reset() { next = nil }
}
