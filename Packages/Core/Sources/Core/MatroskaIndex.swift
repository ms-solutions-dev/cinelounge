import Foundation

/// The seek table of an MKV file — which time is at which position.
///
/// **Without it a film would not be playable, only listenable.** A
/// TV episode is half a gigabyte, a film three. Sending it entirely
/// through the remuxer during playback and keeping the finished pieces would mean
/// three and a half gigabytes in the memory of a TV — that is not a
/// bottleneck, that is a crash.
///
/// So the pieces are created **on demand**: the player asks for piece 47,
/// we fetch exactly its bytes from the file and remux only those. For that it must
/// be known beforehand where piece 47 starts — and that is exactly what the
/// seek table says.
///
/// **And that is why seeking works with it, too.** Whoever jumps into the middle
/// asks for a piece like for any other; the file does not have to be read
/// from the start for that.
///
/// ## Where it is
///
/// At the end of the file — it can only be written once everything in it
/// is fixed. It is found via the directory at the start (`SeekHead`), which
/// does nothing but point to it.
public struct MatroskaIndex: Sendable, Equatable {

    /// A seek point: a keyframe and the position where it lies.
    public struct Entry: Sendable, Equatable {
        /// Time in time units of the file.
        public let time: Int64
        /// Position in the file, **absolute** — already relative to the start of the file.
        public let position: Int
    }

    public var entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    public var isEmpty: Bool { entries.isEmpty }

    // MARK: - Finden

    /// Where in the head the segment begins and where the seek table lies.
    ///
    /// **Both in one pass**, because one is useless without the other: the offsets in the
    /// directory count from the content of the segment, not from the start of
    /// the file. Whoever confuses the two lands a few dozen bytes off
    /// — and from there reads garbage without anything speaking against it.
    public static func locateCues(inHead data: Data) -> (segmentStart: Int, cues: Int)? {
        var offset = 0
        var segmentStart: Int?

        while offset < data.count {
            guard let element = Matroska.element(in: data, at: offset) else { return nil }
            let content = offset + element.headerSize

            if element.id == Matroska.ID.segment {
                segmentStart = content
                offset = content
                continue
            }
            guard let segmentStart else {
                guard let size = element.size else { return nil }
                offset = content + size
                continue
            }
            guard let size = element.size, content + size <= data.count else { return nil }

            if element.id == Matroska.ID.seekHead {
                if let position = cuesPosition(
                    inSeekHead: data.subdata(
                        in: (data.startIndex + content)..<(data.startIndex + content + size)))
                {
                    guard let cues = NetNumber.sum(segmentStart, position) else { return nil }
                    return (segmentStart, cues)
                }
            }
            // Searching further than the first cluster is not worthwhile: after it
            // nothing that helps here comes until the end of the file.
            if element.id == Matroska.ID.cluster { return nil }
            offset = content + size
        }
        return nil
    }

    /// Where the first cluster begins — via the topmost elements of the segment,
    /// like ``locateCues(inHead:)``. For files without an index, whose
    /// index the walk through the clusters then provides.
    public static func locateFirstCluster(inHead data: Data) -> Int? {
        var offset = 0
        var inSegment = false
        while offset < data.count {
            guard let element = Matroska.element(in: data, at: offset) else { return nil }
            let content = offset + element.headerSize
            if element.id == Matroska.ID.segment {
                inSegment = true
                offset = content
                continue
            }
            if inSegment, element.id == Matroska.ID.cluster { return offset }
            guard let size = element.size else { return nil }
            offset = content + size
        }
        return nil
    }

    /// Where a **second SeekHead** lies that the first refers to — for files whose
    /// first SeekHead does not name the cues itself.
    ///
    /// **The finding (diagnostics F-002, 2026-09-28):** "Slebubreit Catblolai" S01E14 had valid
    /// cues, but the SeekHead at the start of the file named only a second SeekHead at the
    /// end of the file and the tags; only that one named the cues. ``locateCues(inHead:)`` found
    /// nothing, and the app went through 888 clusters — around 20 s to the picture, instead of two
    /// small requests. Muxers that only know the index at the end write this pattern.
    public static func locateSeekHeadReference(inHead data: Data) -> (segmentStart: Int, seekHead: Int)? {
        var offset = 0
        var segmentStart: Int?
        while offset < data.count {
            guard let element = Matroska.element(in: data, at: offset) else { return nil }
            let content = offset + element.headerSize
            if element.id == Matroska.ID.segment {
                segmentStart = content
                offset = content
                continue
            }
            guard let size = element.size, content + size <= data.count else { return nil }
            if let segmentStart, element.id == Matroska.ID.seekHead,
                let position = seekPosition(
                    of: Matroska.ID.seekHead,
                    inSeekHead: data.subdata(
                        in: (data.startIndex + content)..<(data.startIndex + content + size))),
                let absolute = NetNumber.sum(segmentStart, position)
            {
                return (segmentStart, absolute)
            }
            if element.id == Matroska.ID.cluster { return nil }
            offset = content + size
        }
        return nil
    }

    /// The cues position from a SeekHead that was read **on its own** (`data` begins
    /// at the SeekHead element itself) — for the second SeekHead of
    /// ``locateSeekHeadReference(inHead:)``.
    public static func cuesPosition(inSeekHeadElement data: Data) -> Int? {
        guard let element = Matroska.element(in: data, at: 0), element.id == Matroska.ID.seekHead,
            let size = element.size, element.headerSize + size <= data.count
        else { return nil }
        return cuesPosition(
            inSeekHead: data.subdata(
                in: (data.startIndex + element.headerSize)..<(data.startIndex + element.headerSize + size)))
    }

    static func cuesPosition(inSeekHead data: Data) -> Int? {
        seekPosition(of: Matroska.ID.cues, inSeekHead: data)
    }

    static func seekPosition(of target: UInt32, inSeekHead data: Data) -> Int? {
        for child in Matroska.children(of: data) where child.id == Matroska.ID.seek {
            let entry = data.subdata(in: child.range)
            var id: UInt32?
            var position: Int?
            for field in Matroska.children(of: entry) {
                let body = entry.subdata(in: field.range)
                if field.id == Matroska.ID.seekID {
                    id = UInt32(truncatingIfNeeded: Matroska.unsigned(body))
                }
                if field.id == Matroska.ID.seekPosition {
                    position = NetNumber.total(Matroska.unsigned(body))
                }
            }
            if id == target, let position { return position }
        }
        return nil
    }

    /// Reads the seek table from the piece of the file in which it lies.
    ///
    /// - Parameters:
    ///   - data: Bytes from the position where the `Cues` element begins.
    ///   - segmentStart: Where the content of the segment begins — the offsets in the
    ///     table count from there.
    ///   - track: Only points of this track count; the video track sets the pace.
    public static func parse(cues data: Data, segmentStart: Int, track: Int) -> MatroskaIndex {
        guard let element = Matroska.element(in: data, at: 0),
            element.id == Matroska.ID.cues
        else { return MatroskaIndex(entries: []) }

        let start = data.startIndex + element.headerSize
        let end = element.size.map { min(start + $0, data.endIndex) } ?? data.endIndex
        guard start < end else { return MatroskaIndex(entries: []) }

        var entries: [Entry] = []
        // **Slice out once, not per seek point** (AP7 · L1,
        // expert review 2026-08-24). There used to be `data.subdata(in: start..<end)`
        // **in** the loop and a second time in its body: for a
        // two-hour film with 1440 seek points the whole seek table was
        // recreated 1440 times — around 37 MB copied over before the first picture
        // is even requested.
        let table = data.subdata(in: start..<end)
        for point in Matroska.children(of: table)
        where point.id == Matroska.ID.cuePoint {
            let body = table.subdata(in: point.range)
            var time: Int64?
            var position: Int?

            for field in Matroska.children(of: body) {
                let value = body.subdata(in: field.range)
                if field.id == Matroska.ID.cueTime { time = NetNumber.int64(Matroska.unsigned(value)) }
                guard field.id == Matroska.ID.cueTrackPositions else { continue }

                var forTrack: Int?
                var cluster: Int?
                for inner in Matroska.children(of: value) {
                    let raw = value.subdata(in: inner.range)
                    if inner.id == Matroska.ID.cueTrack { forTrack = NetNumber.total(Matroska.unsigned(raw)) }
                    if inner.id == Matroska.ID.cueClusterPosition {
                        cluster = NetNumber.total(Matroska.unsigned(raw))
                    }
                }
                // **A table can carry points for several tracks.** Whoever
                // mixes them gets duplicate times and jumps that point to
                // an audio track instead of a picture.
                if forTrack == track, let cluster { position = NetNumber.sum(segmentStart, cluster) }
            }

            if let time, let position {
                entries.append(Entry(time: time, position: position))
            }
        }

        // The order is not fixed in the format; for everything after this it is.
        entries.sort { $0.time < $1.time }
        // **One cluster, one seek point.** If two keyframes lie in
        // one cluster, two points point to the same position; a piece
        // from the first to the second would be zero bytes long and end in a 404.
        // The first point carries the start time, the cluster the rest.
        var seen: Set<Int> = []
        entries = entries.filter { seen.insert($0.position).inserted }
        return MatroskaIndex(entries: entries)
    }

    // MARK: - Einteilen

    /// A piece as the player requests it.
    public struct Piece: Sendable, Equatable {
        public let index: Int
        /// Range in the file — both bounds absolute, the end open.
        public let range: Range<Int>
        public let start: Int64
        public let duration: Double
    }

    /// Splits the file into pieces of at least this length.
    ///
    /// **A piece always begins at a keyframe**, because a seek point
    /// is one. Only the last one becomes shorter than the target time; it becomes longer
    /// where the keyframes lie further apart — the cut is made at
    /// what the file offers, not by the clock.
    ///
    /// **The table is a claim of the file** (remuxer check B1, 2026-09-27).
    /// If its positions do not rise with time, or `fileSize` lies before the last
    /// entry (seek table before the clusters), a range with its end before the
    /// start was produced here — and Swift halted the process. Entries that do not
    /// lie behind their predecessor are discarded; a piece whose end does not lie behind its start
    /// is dropped.
    public func pieces(
        targetDuration: Double, timestampScale: UInt64, fileSize: Int, totalDuration: Double?
    ) -> [Piece] {
        var ascending: [Entry] = []
        for entry in entries where entry.position >= 0 {
            if let last = ascending.last, entry.position <= last.position { continue }
            ascending.append(entry)
        }
        let entries = ascending
        guard !entries.isEmpty else { return [] }
        let secondsPerTick = Double(timestampScale) / Double(NSEC_PER_SEC)

        var pieces: [Piece] = []
        var cursor = 0
        while cursor < entries.count {
            var next = cursor + 1
            while next < entries.count,
                Double(entries[next].time - entries[cursor].time) * secondsPerTick < targetDuration
            {
                next += 1
            }

            let start = entries[cursor]
            let isLast = next >= entries.count
            let end = isLast ? fileSize : entries[next].position
            guard end > start.position else {
                cursor = next
                continue
            }
            let seconds: Double
            if isLast {
                seconds = max(
                    0.001,
                    (totalDuration ?? Double(start.time) * secondsPerTick)
                        - Double(start.time) * secondsPerTick)
            } else {
                seconds = Double(entries[next].time - start.time) * secondsPerTick
            }

            pieces.append(
                Piece(
                    index: pieces.count,
                    range: start.position..<end,
                    start: start.time,
                    duration: seconds
                ))
            cursor = next
        }
        return pieces
    }
}
