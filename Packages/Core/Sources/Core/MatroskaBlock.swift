import Foundation

extension Matroska {

    /// A block as it sits in the file — before any interpretation.
    public struct ParsedBlock: Sendable, Equatable {
        public let track: Int
        /// Offset from the cluster's timestamp, in time units. May be negative:
        /// pictures are written in decoding order, and that runs ahead
        /// of presentation.
        public let relativeTimestamp: Int16
        public let flags: UInt8
        /// A block can carry several frames — see ``frames(in:lacing:)``.
        public let frames: [Data]

        /// Meaningful only for `SimpleBlock`. In a `BlockGroup` it is instead
        /// the absence of a `ReferenceBlock` that says a picture stands
        /// on its own.
        public var isKeyframe: Bool { flags & 0x80 != 0 }
    }

    /// Splits a block into head and frames.
    public static func parseBlock(_ data: Data) -> ParsedBlock? {
        guard let track = varint(in: data, at: 0) else { return nil }
        var offset = track.width
        guard offset + 3 <= data.count else { return nil }

        let base = data.startIndex
        let relative = Int16(
            bitPattern: UInt16(data[base + offset]) << 8 | UInt16(data[base + offset + 1]))
        offset += 2
        let flags = data[base + offset]
        offset += 1

        guard
            let frames = frames(
                in: data.subdata(in: (base + offset)..<data.endIndex),
                lacing: (flags & 0x06) >> 1)
        else { return nil }

        return ParsedBlock(
            track: Int(truncatingIfNeeded: track.value), relativeTimestamp: relative, flags: flags,
            frames: frames)
    }

    /// Separates the frames of a block — the four kinds of lacing.
    ///
    /// **Why this exists at all:** an audio frame is a few hundred bytes
    /// large, a block head six. At fifty frames per second the head would be
    /// noticeable ballast, so several frames may sit in one block — with
    /// three different ways of stating their lengths, from three different
    /// decades.
    ///
    /// **For video this practically never happens, for audio constantly.** Whoever does not
    /// implement it gets audio frames glued together from several, and
    /// a decoder that stops after the first: audio that breaks off after a second
    /// without an error anywhere.
    ///
    /// **Every length is a claim of the file** (remuxer check B3, 2026-09-27):
    /// an EBML lacing with a frame count of one halted the process here (`1..<0`), and
    /// the sum of the differences must not overflow. A block that does not add up
    /// is discarded — `nil`, like any other unreadable spot.
    static func frames(in data: Data, lacing: UInt8) -> [Data]? {
        guard lacing != 0 else { return data.isEmpty ? [] : [data] }
        guard let count = data.first.map({ Int($0) + 1 }) else { return nil }

        var offset = 1
        var sizes: [Int] = []
        let base = data.startIndex

        switch lacing {
        case 1:
            // Xiph: each length as a sequence of 255s, terminated by a
            // smaller byte. The last length follows from the remainder.
            for _ in 0..<(count - 1) {
                var size = 0
                while offset < data.count {
                    let byte = Int(data[base + offset])
                    offset += 1
                    size += byte
                    if byte != 255 { break }
                }
                sizes.append(size)
            }
        case 2:
            // Fixed: all the same length, the length follows from the division.
            let remaining = data.count - offset
            guard count > 0, remaining % count == 0 else { return nil }
            sizes = Array(repeating: remaining / count, count: count - 1)
        case 3:
            // EBML: the first length as a number, each further one as a **difference**
            // from the previous — signed, with an offset that depends on the
            // byte count.
            guard count >= 2 else { break }
            guard let firstItem = varint(in: data, at: offset), let leading = NetNumber.total(firstItem.value)
            else { return nil }
            offset += firstItem.width
            var previous = leading
            sizes.append(previous)
            for _ in 0..<(count - 2) {
                guard let delta = varint(in: data, at: offset), let raw = NetNumber.total(delta.value)
                else { return nil }
                offset += delta.width
                let bias = (1 << (7 * delta.width - 1)) - 1
                guard let next = NetNumber.sum(previous, raw - bias), next >= 0 else {
                    return nil
                }
                previous = next
                sizes.append(previous)
            }
        default: return nil
        }

        var frames: [Data] = []
        for size in sizes {
            guard size >= 0, size <= data.count - offset else { return nil }
            frames.append(data.subdata(in: (base + offset)..<(base + offset + size)))
            offset += size
        }
        guard offset <= data.count else { return nil }
        frames.append(data.subdata(in: (base + offset)..<data.endIndex))
        return frames
    }
}
