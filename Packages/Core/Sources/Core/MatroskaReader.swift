import Foundation

/// Reads an MKV file **as a stream** — bite by bite, without holding it.
///
/// **The reason this is not simply called "open file":** a TV episode
/// is half a gigabyte, a film three. It lies on the server, it arrives
/// over the network, and the viewer wants to see a picture after one second — loading it
/// first and then reading it is not an option. So the same applies here
/// as for the live channel: read what is there, and wait for what
/// is missing.
///
/// ## What makes life hard for this reader
///
/// **The order in the head is not fixed.** In one test file
/// `Tracks` comes before `Info`, in the next after it, and in between lie
/// filler elements. Therefore nothing is expected, everything is collected.
///
/// **Lengths may stay open.** Whoever writes a file while recording
/// does not know the length of the segment. An element without a length field ends
/// only where something begins that can no longer be a child.
///
/// **Most of the file is none of our business.** Chapters, seek tables,
/// attached cover images — easily ten megabytes together. They are not
/// read and not even kept, but discarded as they pass.
public final class MatroskaReader {

    /// A block with its absolute time.
    public struct Block: Sendable, Equatable {
        public let track: Int
        /// Absolute, in time units of the file — see ``Matroska/Header/timestampScale``.
        public let timestamp: Int64
        public let isKeyframe: Bool
        /// Only set where the file names it (`BlockDuration`).
        public let duration: Int64?
        public let frames: [Data]
    }

    /// What was in the head. It keeps growing until the first cluster.
    public private(set) var header = Matroska.Header()

    /// Whether the head is complete — true as soon as the first cluster begins.
    ///
    /// **The only reliable moment.** A `Tracks` element can still come
    /// after the `Info`, a second one even after the first cluster
    /// (then it is an addition). The start of the first cluster is the
    /// point from which the head suffices for playback.
    public private(set) var isHeaderComplete = false

    /// Whether the reader has lost its bearings.
    ///
    /// **With EBML there is no finding your way back.** A transport stream has a marker
    /// every 188 bytes at which you can realign; here every
    /// position depends on the length of the previous element. Whoever is wrong once
    /// is wrong for the rest of the file — which is why it aborts and does not
    /// guess.
    public private(set) var isBroken = false

    /// The largest cluster time considered readable, in time units of the file.
    ///
    /// **2⁵² — and thus headroom for every calculation after it** (remuxer check, follow-up
    /// 2026-09-27). The times continue through ``DecodeOrder``, the picture axis and the
    /// grid, which form sums and differences of two times. With time scale one,
    /// a cluster time up to `Int64.max` would otherwise be "representable", and the first sum would
    /// overflow. 2⁵² milliseconds are 142 000 years; no film comes near that, and the
    /// values stay exact in `Double`.
    static let maximumTime: Int64 = 1 << 52

    /// From what size an element is skipped instead of kept.
    static let maximumElement = 32 << 20

    private var buffer = Data()
    private var cursor = 0
    /// Absolute Position des Pufferanfangs im Gesamtstrom.
    private var consumed = 0
    /// How many bytes are still discarded before reading resumes.
    private var skipping = 0

    private struct Open {
        let id: UInt32
        /// Absolute end position, or `nil` for an open length.
        let end: Int?
    }
    private var stack: [Open] = []
    private var clusterTime: Int64 = 0

    /// What is collected inside a `BlockGroup` until it closes.
    private var group: (block: Matroska.ParsedBlock, duration: Int64?, hasReference: Bool)?

    public init() {}

    // MARK: - Lesen

    public func read(_ chunk: Data) -> [Block] {
        guard !isBroken else { return [] }
        buffer.append(chunk)

        var blocks: [Block] = []
        while !isBroken {
            if skipping > 0 {
                let available = buffer.count - cursor
                guard available > 0 else { break }
                let take = min(skipping, available)
                cursor += take
                skipping -= take
                continue
            }

            closeFinished(into: &blocks)
            guard cursor < buffer.count else { break }

            guard let element = Matroska.element(in: buffer, at: cursor) else {
                // With plenty of bytes in the buffer, only what is not an element fails.
                if buffer.count - cursor >= 2 * Matroska.maximumVarIntWidth { isBroken = true }
                break
            }
            guard step(element, into: &blocks) else { break }
        }

        compact()
        return blocks
    }

    /// Hands out what was still open — for the end of a file.
    public func flush() -> [Block] {
        var blocks: [Block] = []
        emitGroup(into: &blocks)
        return blocks
    }

    // MARK: - Innen

    /// Processes an element. `false` means: bytes are still missing.
    private func step(_ element: Matroska.Element, into blocks: inout [Block]) -> Bool {
        let position = consumed + cursor
        let contentStart = position + element.headerSize

        // A cluster without a length field ends where something begins that cannot be
        // a child of a cluster.
        if Self.levelOne.contains(element.id) { closeOpenEnded(into: &blocks) }

        if Matroska.descendable.contains(element.id) {
            stack.append(Open(id: element.id, end: element.size.map { contentStart + $0 }))
            if element.id == Matroska.ID.cluster {
                clusterTime = 0
                isHeaderComplete = true
            }
            if element.id == Matroska.ID.blockGroup {
                emitGroup(into: &blocks)
            }
            cursor += element.headerSize
            return true
        }

        // An element that is not entered and whose length is missing
        // cannot be skipped — here reading honestly ends.
        guard let size = element.size else {
            isBroken = true
            return false
        }

        guard Self.wanted.contains(element.id), size <= Self.maximumElement else {
            cursor += element.headerSize
            skipping = size
            return true
        }

        let needed = element.headerSize + size
        guard buffer.count - cursor >= needed else { return false }

        let start = buffer.startIndex + cursor + element.headerSize
        let body = buffer.subdata(in: start..<(start + size))
        cursor += needed
        absorb(element.id, body, into: &blocks)
        return true
    }

    /// Takes over a read element.
    ///
    /// **A cluster time that cannot be computed is none** (remuxer check B4,
    /// 2026-09-27): eight bytes of `0xFF` halted the process on conversion. If it lies
    /// above ``maximumTime`` or overflows in nanoseconds, the file is considered
    /// unreadable — the remuxer says so as ``MatroskaRemuxer/Refusal/fileIsUnreadable``.
    private func absorb(_ id: UInt32, _ body: Data, into blocks: inout [Block]) {
        switch id {
        case Matroska.ID.tracks:
            let found = Matroska.tracks(inTracksElement: body)
            if !found.isEmpty { header.tracks = found }
        case Matroska.ID.info:
            let (scale, duration) = Matroska.info(inInfoElement: body)
            if let scale, scale > 0 { header.timestampScale = scale }
            if let duration { header.duration = duration }
        case Matroska.ID.clusterTimestamp:
            guard let time = NetNumber.int64(Matroska.unsigned(body)), time <= Self.maximumTime,
                NetNumber.toNanoseconds(time, scale: header.timestampScale) != nil
            else {
                isBroken = true
                return
            }
            clusterTime = time
        case Matroska.ID.simpleBlock:
            guard let parsed = Matroska.parseBlock(body) else { return }
            blocks.append(block(from: parsed, isKeyframe: parsed.isKeyframe, duration: nil))
        case Matroska.ID.block:
            guard let parsed = Matroska.parseBlock(body) else { return }
            group = (parsed, group?.duration, group?.hasReference ?? false)
        case Matroska.ID.blockDuration:
            let value = min(Int64(clamping: Matroska.unsigned(body)), Self.maximumTime)
            if let existing = group {
                group = (existing.block, value, existing.hasReference)
            }
        case Matroska.ID.referenceBlock:
            // **The field is a reference to another picture.** That it is there
            // is enough: a picture with a predecessor does not stand on its own.
            if let existing = group {
                group = (existing.block, existing.duration, true)
            }
        default: break
        }
    }

    private func block(
        from parsed: Matroska.ParsedBlock, isKeyframe: Bool, duration: Int64?
    ) -> Block {
        Block(
            track: parsed.track,
            timestamp: NetNumber.saturatedSum(clusterTime, Int64(parsed.relativeTimestamp)),
            isKeyframe: isKeyframe,
            duration: duration,
            frames: parsed.frames
        )
    }

    /// Closes everything that is finished according to its length field.
    private func closeFinished(into blocks: inout [Block]) {
        let position = consumed + cursor
        while let top = stack.last, let end = top.end, end <= position {
            if top.id == Matroska.ID.blockGroup { emitGroup(into: &blocks) }
            stack.removeLast()
        }
    }

    /// Closes containers whose length stayed open.
    private func closeOpenEnded(into blocks: inout [Block]) {
        while let top = stack.last, top.end == nil, top.id != Matroska.ID.segment {
            if top.id == Matroska.ID.blockGroup { emitGroup(into: &blocks) }
            stack.removeLast()
        }
    }

    private func emitGroup(into blocks: inout [Block]) {
        guard let group else { return }
        blocks.append(
            block(from: group.block, isKeyframe: !group.hasReference, duration: group.duration))
        self.group = nil
    }

    private func compact() {
        guard cursor > 0 else { return }
        if cursor >= buffer.count {
            consumed += cursor
            buffer.removeAll(keepingCapacity: true)
            cursor = 0
        } else if cursor > 1 << 20 {
            consumed += cursor
            buffer.removeFirst(cursor)
            cursor = 0
        }
    }

    /// Elements whose content is really needed.
    static let wanted: Set<UInt32> = [
        Matroska.ID.tracks, Matroska.ID.info, Matroska.ID.clusterTimestamp,
        Matroska.ID.simpleBlock, Matroska.ID.block, Matroska.ID.blockDuration,
        Matroska.ID.referenceBlock,
    ]

    /// What may stand directly in the segment — and thus ends an open
    /// cluster.
    static let levelOne: Set<UInt32> = [
        Matroska.ID.seekHead, Matroska.ID.info, Matroska.ID.tracks, Matroska.ID.cluster,
        Matroska.ID.cues, Matroska.ID.attachments, Matroska.ID.chapters, Matroska.ID.tags,
    ]
}
