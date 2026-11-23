import CoreMedia
import Foundation

/// Where the remuxer sends its finished packets.
///
/// **Since 2026-09-03 the remuxer knows two consumers, and this contract separates it from
/// both.** Until then ``TransportRemuxer`` built its ``FragmentWriter`` itself and thus knew
/// that fMP4 pieces come out at the back. That was the one place where the whole live path
/// hung on AVAssetWriter — and on its rule that every piece must begin with a keyframe
/// (`-11876`, shown on a channel, see ``TransportRemuxer/flushSegment()``). With a channel
/// with ten seconds between two keyframes that meant: twenty seconds of broadcast before
/// the engine gets the address.
///
/// The second consumer is ``SampleQueue``: It holds the packets for an engine that decodes
/// them **directly** — without container, without piece, without playlist. For it there is
/// no piece boundary and thus no wait for the second keyframe.
///
/// What arrives here is already finished: timestamps straightened, fields paired, audio in
/// a format the hardware outputs. The consumer needs to know nothing more about the stream.
public protocol SampleSink: AnyObject, Sendable {

    /// Whether anything still goes in at all.
    ///
    /// **A failed consumer otherwise swallows silently** — that was finding AP6 · Q1 for the
    /// writer, and it applies to every consumer: Whoever returns `false` must have the reason
    /// ready here.
    var failure: Error? { get }

    /// Accepts a picture — in **decode order**, with straightened time.
    @discardableResult
    func append(video sample: CMSampleBuffer) -> Bool

    /// Accepts an audio packet.
    @discardableResult
    func append(audio sample: CMSampleBuffer) -> Bool

    /// A break in the stream: The connection broke, the next fetch begins at a new keyframe.
    /// What has been started is to be rescued.
    func discontinuity()

    /// Nothing more is coming — a file has ended.
    func finish() async

    /// The audio track was switched: What of the old one still waits is worthless, and the
    /// next may come in a different format.
    func audioTrackChanged()

    /// Whether the consumer demands picture and audio **interleaved** — i.e. holds back one
    /// track until the other has caught up.
    ///
    /// `AVAssetWriter` does this (the interleaving lock, see ``FragmentWriter/appendAudio(_:)``);
    /// whoever feeds it must hold the audio back behind the last picture, otherwise it
    /// expires. Our own writer collects both tracks separately and needs none of that.
    var needsInterleavedInput: Bool { get }
}

extension SampleSink {
    /// The default for consumers that know no switch — the writers.
    public func audioTrackChanged() {}

    /// The default: no holding back necessary.
    public var needsInterleavedInput: Bool { false }
}

extension FragmentWriter: SampleSink {

    /// See ``SampleSink/needsInterleavedInput``: the system writer interleaves and holds back.
    public var needsInterleavedInput: Bool { true }

    public func append(video sample: CMSampleBuffer) -> Bool { append(sample) }

    public func append(audio sample: CMSampleBuffer) -> Bool { appendAudio(sample) }

    /// On a break it cuts — what has been started thus becomes the last piece instead of the
    /// lost one.
    public func discontinuity() { flushSegment() }
}
