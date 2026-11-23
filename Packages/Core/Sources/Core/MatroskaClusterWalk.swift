import CryptoKit
import Foundation

/// A seek index for Matroska files **without** cues — from a walk
/// through the clusters.
///
/// **Why it is needed** (F-008, 2026-09-04): "Bringrarn Piosiaspeit Slausnonspel" on the
/// server is 6.46 GB, its segment head promises 11.7 GB, and the
/// index lies, according to SeekHead, past the end of the file — the file is
/// truncated. Without an index the file remuxer could not seek,
/// fell back to the server, and the server, with its lead time, needed over
/// half a minute to the picture. Yet every cluster contains what the
/// index would say: its timestamp — and its length says where the
/// next one begins. A walk from cluster to cluster is therefore an
/// index: one tiny range request per cluster, four in parallel
/// spread over the file, a few seconds for a feature film. The
/// result goes into the cache (``MatroskaIndexCache``); the
/// second start of the same file has it immediately.
///
/// What the walk cannot do: clusters **without a length field** (live muxers,
/// aborted ffmpeg streams). Then it stays with the fallback to the server.
public enum MatroskaClusterWalk {

    /// The head of a cluster: where it lies, where it ends, what time it carries —
    /// and whether its first picture block is a keyframe.
    ///
    /// **The keyframe decides whether a piece may begin here**
    /// (F-020: "2 pictures per 10 seconds, no audio"). The remuxer discards
    /// everything before the first keyframe; a piece that begins at a cluster
    /// without a keyframe is empty — and the clusters of this file
    /// were one second long, the keyframes seconds apart.
    public struct ClusterHead: Equatable, Sendable {
        public let position: Int
        public let end: Int
        public let time: Int64
        /// `nil` if no picture block was in the window read.
        public let startsWithKeyframe: Bool?
    }

    /// How much is read per cluster: head, CRC-32, timestamp — and the
    /// first blocks, until the first picture block shows its flag. Audio blocks
    /// before it weigh a few kilobytes.
    public static let headBytes = 16 << 10

    /// Reads the cluster head at `offset` in `data`; `base` is the position
    /// of `data` in the file. `nil` if no cluster with known
    /// length and timestamp begins there.
    public static func head(
        in data: Data, at offset: Int, base: Int, videoTrack: Int? = nil
    ) -> ClusterHead? {
        guard offset >= 0, offset + 4 <= data.count,
            let element = Matroska.element(in: data, at: offset),
            element.id == Matroska.ID.cluster,
            let size = element.size, size > 0
        else { return nil }
        let end = base + offset + element.headerSize + size
        var cursor = offset + element.headerSize
        var time: Int64?
        // CRC-32 and Void may stand before the timestamp — ffmpeg does that.
        // After that the blocks, until the first picture block shows its flag.
        for _ in 0..<64 {
            guard cursor < data.count, let child = Matroska.element(in: data, at: cursor),
                let childSize = child.size
            else { break }
            let content = cursor + child.headerSize
            switch child.id {
            case Matroska.ID.clusterTimestamp:
                guard childSize >= 1, childSize <= 8, content + childSize <= data.count else {
                    return nil
                }
                time = Int64(
                    clamping: Matroska.unsigned(
                        data.subdata(
                            in: (data.startIndex + content)..<(data.startIndex + content + childSize))))
            case Matroska.ID.crc32, Matroska.ID.void:
                break
            case Matroska.ID.simpleBlock:
                guard let time else { return nil }
                guard let videoTrack else {
                    return ClusterHead(position: base + offset, end: end, time: time, startsWithKeyframe: nil)
                }
                if let track = Matroska.varint(in: data, at: content),
                    Int(track.value) == videoTrack
                {
                    let flagsAt = data.startIndex + content + track.width + 2
                    guard flagsAt < data.endIndex else {
                        return ClusterHead(
                            position: base + offset, end: end, time: time, startsWithKeyframe: nil)
                    }
                    return ClusterHead(
                        position: base + offset, end: end, time: time,
                        startsWithKeyframe: data[flagsAt] & 0x80 != 0)
                }
            case Matroska.ID.blockGroup:
                guard let time else { return nil }
                guard let videoTrack else {
                    return ClusterHead(position: base + offset, end: end, time: time, startsWithKeyframe: nil)
                }
                // Inside the group: the block and, if present, a reference —
                // a picture block without a reference is a keyframe.
                var inner = content
                var isVideo = false
                var hasReference = false
                let groupEnd = min(content + childSize, data.count)
                while inner < groupEnd, let part = Matroska.element(in: data, at: inner),
                    let partSize = part.size
                {
                    let partContent = inner + part.headerSize
                    if part.id == Matroska.ID.block,
                        let track = Matroska.varint(in: data, at: partContent)
                    {
                        isVideo = Int(track.value) == videoTrack
                    }
                    if part.id == Matroska.ID.referenceBlock { hasReference = true }
                    inner = partContent + partSize
                }
                if isVideo {
                    return ClusterHead(
                        position: base + offset, end: end, time: time, startsWithKeyframe: !hasReference)
                }
            default:
                // Something that is not a cluster child: not a cluster.
                if time == nil { return nil }
            }
            cursor = content + childSize
        }
        guard let time else { return nil }
        return ClusterHead(position: base + offset, end: end, time: time, startsWithKeyframe: nil)
    }

    /// Sucht ab `from` den ersten Cluster-Kopf in `data`.
    public static func scan(
        _ data: Data, base: Int, from: Int = 0, videoTrack: Int? = nil
    ) -> ClusterHead? {
        let marker = Data([0x1F, 0x43, 0xB6, 0x75])
        var cursor = data.startIndex + max(0, from)
        while cursor < data.endIndex,
            let hit = data.range(of: marker, options: [], in: cursor..<data.endIndex)
        {
            let offset = hit.lowerBound - data.startIndex
            if let found = head(in: data, at: offset, base: base, videoTrack: videoTrack) {
                return found
            }
            cursor = hit.lowerBound + 1
        }
        return nil
    }

    /// The walk through the file — in parallel in `workers` sections.
    ///
    /// - Parameters:
    ///   - firstCluster: Position of the first cluster (from the head).
    ///   - window: How much is read at once when a section has to
    ///     search for its first cluster.
    /// How many sections run at the same time — **four, and that is a limit for the
    /// disk, not for the network.**
    ///
    /// Until 2026-09-27 it was 32, justified with F-020: 4775 clusters in 56 s with
    /// eight sections, "with 32 it is seconds". That calculated as if the time per
    /// request were pure latency. The on-device test of build 1332 (report `F-021`) showed the
    /// opposite: 31 sections searched for their first cluster at the same time, 2 MiB each, spread over
    /// the whole file, against a server with a hard disk — every request took
    /// 4 to 12.5 s because the read head jumped between 31 places. The same lesson as with
    /// the read-ahead of pieces (2026-09-05, "one worker"): the "slow disk" was the
    /// consequence of the parallelism.
    ///
    /// **Four and not one**, because the walk issues a small request per cluster and
    /// over the tunnel every response costs a round trip; with no overlap at all the
    /// walk would turn into waiting on the line there. A disk tolerates four read heads, 32 not.
    /// The connection carries exactly that many: ``HTTPByteRangeSource/parallelSession``.
    public static let defaultWorkers = 4

    /// This many workers and connections has a walk on its own line
    /// (``HTTPByteRangeSource/runSession``) — no more than playback, so that it
    /// does not take anything away from it when it finishes in the background.
    ///
    /// **Four instead of two** (diagnostics D3AA, 2026-10-11: "Hanplospand", 4.1 GB without
    /// a seek index, 3492 clusters, 86 s to the first picture). Measured against Jellyfin on
    /// cold files (8 and 15 GB, `scratchpad/gangprobe.py`): a 16 KB head request costs
    /// 17–24 ms with two connections, 11–12 ms with four, 10 ms with eight — from four on
    /// the disk does not carry further. Four halves the walk, more brings nothing and would take
    /// the line away from playback. That a walk with more read heads chokes a disk is noted
    /// at ``defaultWorkers`` (F-021).
    public static let gearConnections = 4

    public static func index(
        source: ByteRangeSource, firstCluster: Int, fileSize: Int, videoTrack: Int? = nil,
        workers: Int = defaultWorkers, window: Int = 2 << 20
    ) async throws -> [ClusterHead] {
        guard firstCluster < fileSize else { return [] }
        let span = fileSize - firstCluster
        let count = max(1, min(workers, span / max(1, window)))
        let bounds = (0...count).map { firstCluster + NetNumber.portion(span, mal: $0, finished: count) }

        var collected: [ClusterHead] = []
        try await withThrowingTaskGroup(of: [ClusterHead].self) { group in
            for slot in 0..<count {
                let region = bounds[slot]..<bounds[slot + 1]
                group.addTask {
                    try await walk(
                        source: source, region: region, knownStart: slot == 0,
                        fileSize: fileSize, window: window, videoTrack: videoTrack)
                }
            }
            for try await part in group { collected += part }
        }
        var seen = Set<Int>()
        return collected.sorted { $0.position < $1.position }
            .filter { seen.insert($0.position).inserted }
    }

    /// The places where a piece may begin: the clusters with a
    /// keyframe — or all of them if the file does not provide that (then
    /// longer pieces help, see ``MatroskaFileSession``).
    public static func entries(
        from heads: [ClusterHead]
    ) -> (entries: [MatroskaIndex.Entry], keyframesKnown: Bool) {
        let keyed = heads.filter { $0.startsWithKeyframe == true }
        if keyed.count >= 2 {
            return (keyed.map { MatroskaIndex.Entry(time: $0.time, position: $0.position) }, true)
        }
        return (heads.map { MatroskaIndex.Entry(time: $0.time, position: $0.position) }, false)
    }

    /// The segment-level elements the walk jumps over.
    static let sideClusters: Set<UInt32> = [
        Matroska.ID.seekHead, Matroska.ID.info, Matroska.ID.tracks, Matroska.ID.cues,
        Matroska.ID.attachments, Matroska.ID.chapters, Matroska.ID.tags, Matroska.ID.void,
        Matroska.ID.crc32,
    ]

    /// Where the walk continues if at `position` there is not a cluster but another
    /// segment-level element with a length field — `nil` otherwise.
    ///
    /// **Jump over whole elements, do not search byte by byte** (remuxer check B6,
    /// 2026-09-27). Behind the last cluster there are often tags, chapters or cues. The
    /// search read window after window there; if the last one was shorter than ``headBytes``,
    /// it advanced by **one** byte per round, each round its own request: 16 387 requests for
    /// a file with one cluster, minutes over the network, and ``MatroskaFileSession/start()``
    /// waited for it. The spot behind a cluster is an element boundary; whatever
    /// is there says itself how long it is.
    static func skip(_ probe: Data, at position: Int) -> Int? {
        guard let element = Matroska.element(in: probe, at: 0),
            sideClusters.contains(element.id),
            let length = element.totalSize, length > 0,
            let next = NetNumber.sum(position, length)
        else { return nil }
        return next
    }

    private static func walk(
        source: ByteRangeSource, region: Range<Int>, knownStart: Bool, fileSize: Int, window: Int,
        videoTrack: Int?
    ) async throws -> [ClusterHead] {
        var heads: [ClusterHead] = []
        var position = region.lowerBound
        var needsSearch = !knownStart

        while position < region.upperBound {
            try Task.checkCancellation()
            if !needsSearch {
                let probe = try await source.bytes(
                    in: position..<(position + min(headBytes, fileSize - position)))
                if let found = head(in: probe, at: 0, base: position, videoTrack: videoTrack) {
                    heads.append(found)
                    position = found.end
                    continue
                }
                if let next = skip(probe, at: position) {
                    position = next
                    continue
                }
                needsSearch = true
            }
            // Searching: window by window, until a head is found or the section
            // ends. The cluster found still counts even if
            // it begins behind the section — the next section
            // does not find it, because it searches from its boundary and clusters
            // begin in the middle of the window; duplicate positions drop out when collecting.
            var found: ClusterHead?
            var cursor = position
            while found == nil, cursor < region.upperBound {
                let chunk = try await source.bytes(
                    in: cursor..<(cursor + min(window, fileSize - cursor)))
                guard !chunk.isEmpty else { break }
                found = scan(chunk, base: cursor, videoTrack: videoTrack)
                if found == nil, cursor + chunk.count >= fileSize { break }
                // A cluster can lie on the window boundary — step back a little
                // so that its head lies entirely in the next window.
                cursor += max(1, chunk.count - headBytes)
            }
            guard let found else { break }
            heads.append(found)
            position = found.end
            needsSearch = false
        }
        return heads
    }
}

/// The cache for indexes found by walking — one file per source.
public enum MatroskaIndexCache {

    static var directory: URL {
        let base =
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("matroska-verzeichnis", isDirectory: true)
    }

    /// The key of a source: address without query plus length — the same
    /// file under the same address, and a different length is a different
    /// file.
    public static func key(for url: URL, size: Int) -> String {
        var trimmed = url
        if var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            parts.query = nil
            trimmed = parts.url ?? url
        }
        // "v3": since the index **also carries whether its clusters are keyframes**
        // (AP31, 2026-09-23). The version in the key is more than
        // tidiness here — it is the fix: a `v2` index does not carry this knowledge,
        // and that is exactly what triggered the reported bug. It is therefore not
        // found at all, the walk runs anew once, and that costs seconds
        // instead of a film that does not start.
        let digest = SHA256.hash(data: Data("v3|\(trimmed.absoluteString)|\(size)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The head before the entries — **sixteen bytes, so the length check stays.**
    ///
    /// The old version recognised a usable index by its length
    /// being divisible by sixteen. A head of a different length would have silently
    /// disabled this check — it would keep passing without meaning anything.
    private static let identifier: [UInt8] = Array("MKVIDX".utf8)

    /// What an index found by walking knows about itself.
    public struct Directory: Sendable {
        public let entries: [MatroskaIndex.Entry]
        /// Whether the positions in it are **keyframes**.
        ///
        /// **This is the information this type exists for** (AP31, 2026-09-23).
        /// Without it the second attempt read the same positions and took them for
        /// keyframes — the pieces became short, began in the middle of a
        /// group of pictures, and no picture came.
        public let keyframesKnown: Bool
    }

    public static func load(key: String) -> Directory? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(key + ".bin")),
            data.count % 16 == 0, data.count > 16,
            Array(data.prefix(identifier.count)) == identifier
        else { return nil }
        let keyframesKnown = data[data.startIndex + identifier.count] == 1
        var entries: [MatroskaIndex.Entry] = []
        entries.reserveCapacity(data.count / 16 - 1)
        data.withUnsafeBytes { bytes in
            for index in stride(from: 16, to: data.count, by: 16) {
                let time = bytes.loadUnaligned(fromByteOffset: index, as: Int64.self)
                let position = bytes.loadUnaligned(fromByteOffset: index + 8, as: Int64.self)
                entries.append(
                    .init(time: Int64(littleEndian: time), position: Int(Int64(littleEndian: position))))
            }
        }
        guard !entries.isEmpty else { return nil }
        return Directory(entries: entries, keyframesKnown: keyframesKnown)
    }

    public static func save(
        _ entries: [MatroskaIndex.Entry], keyframesKnown: Bool, key: String
    ) {
        guard !entries.isEmpty else { return }
        var data = Data(capacity: (entries.count + 1) * 16)
        data.append(contentsOf: identifier)
        data.append(keyframesKnown ? 1 : 0)
        data.append(contentsOf: [UInt8](repeating: 0, count: 16 - identifier.count - 1))
        for entry in entries {
            withUnsafeBytes(of: entry.time.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: Int64(entry.position).littleEndian) { data.append(contentsOf: $0) }
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent(key + ".bin"), options: .atomic)
    }

    public static func forget(key: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(key + ".bin"))
    }
}
