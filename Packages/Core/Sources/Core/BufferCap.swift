import CoreMedia
import Foundation

/// A cap for queues of packets: by count **and** by bytes.
///
/// **Packets are no measure of memory** (AP73, 2026-10-11). Twenty-five hundred
/// frames are a few dozen megabytes for an SD channel, for UHD at 17 Mbit/s
/// over two hundred — the same cap, ten times the memory. The byte cap therefore
/// applies in addition: whatever breaks either of the two is dropped, and as before the oldest.
public struct BufferCap: Sendable, Equatable {
    public let maximumCount: Int
    public let maximumBytes: Int

    public init(count: Int, bytes: Int) {
        maximumCount = count
        maximumBytes = bytes
    }

    /// Whether something has to be dropped at this fill level.
    public func overflows(count: Int, bytes: Int) -> Bool {
        count > maximumCount || bytes > maximumBytes
    }

    /// How much a packet weighs — the payload, not the frame.
    public static func size(_ sample: CMSampleBuffer) -> Int {
        CMSampleBufferGetTotalSampleSize(sample)
    }
}

/// A queue that counts its bytes along and trims itself on append.
///
/// The sum runs along, instead of measuring the queue at every packet; when
/// trimming, it drops at the front until ``BufferCap`` is satisfied.
struct CappedQueue<Element> {
    private(set) var elements: [Element] = []
    private(set) var bytes = 0
    let cap: BufferCap
    private let size: (Element) -> Int

    init(cap: BufferCap, size: @escaping (Element) -> Int) {
        self.cap = cap
        self.size = size
    }

    var count: Int { elements.count }
    var isEmpty: Bool { elements.isEmpty }
    var first: Element? { elements.first }
    var last: Element? { elements.last }

    /// Appends and trims at the front; returns how many packets were dropped in the process.
    @discardableResult
    mutating func append(_ element: Element) -> Int {
        elements.append(element)
        bytes += size(element)
        var evicted = 0
        while cap.overflows(count: elements.count, bytes: bytes), elements.count > 1 {
            bytes -= size(elements.removeFirst())
            evicted += 1
        }
        return evicted
    }

    mutating func removeFirst() -> Element {
        let element = elements.removeFirst()
        bytes -= size(element)
        return element
    }

    mutating func removeAll() {
        elements.removeAll()
        bytes = 0
    }
}
