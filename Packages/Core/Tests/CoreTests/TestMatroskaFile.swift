import Foundation

@testable import Core

/// Builds a **complete** MKV file from real blocks — with a seek table.
///
/// **Why this is needed.** The test files in the index are beginnings of real
/// titles, one megabyte each. For everything to do with reading, that is exactly
/// right: real material, real quirks. For everything to do with **seeking**
/// it is useless — the seek table sits at the end of the file, and
/// the end is missing.
///
/// Putting a whole series episode into the repo is not an option (400 megabytes).
/// So here a small but complete file is built from the available bytes:
/// real pictures, real sound, correct structure, with index and
/// seek table in place.
///
/// **Incidentally this tests the reader against an independent writer.** What
/// comes out here is not from the same pen as what is read — where both agree,
/// the probability is low that both share the same wrong
/// assumption.
enum TestMatroskaFile {

    /// - Parameter clustersAtKeyframes: Whether every cluster begins at a
    ///   keyframe (the way the test files have always been built) — or
    ///   **by the clock**, like "K for Kestrel" (F-023): then the
    ///   keyframes lie somewhere inside the cluster, and the seek table points to
    ///   the cluster that contains them. Exactly this construction made the tail
    ///   of the file repackager end before the keyframe.
    /// - Parameter omitDuration: Whether the `Info` element stays entirely without `Duration` —
    ///   for testing files whose header does not name the runtime (repackager check,
    ///   finding 4, 2026-09-27). `header.duration ?? 0` would otherwise always write a number,
    ///   and `Duration: 0` reads differently from "no value at all".
    static func make(
        header: Matroska.Header,
        blocks: [MatroskaReader.Block],
        clusterSeconds: Double = 1.0,
        clustersAtKeyframes: Bool = true,
        omitDuration: Bool = false
    ) -> Data {
        let videoTrack = header.video?.number ?? 1
        let ticksPerCluster = Int64(
            clusterSeconds * Double(NSEC_PER_SEC) / Double(header.timestampScale))

        // MARK: Build clusters — each starts at a keyframe, or by the clock.
        var clusters: [(time: Int64, body: Data, keyframes: [Int64])] = []
        var current = Data()
        var currentTime: Int64 = 0
        var currentKeyframes: [Int64] = []
        var hasCurrent = false

        for block in blocks {
            let startsNew =
                clustersAtKeyframes
                ? block.track == videoTrack && block.isKeyframe
                    && (!hasCurrent || block.timestamp - currentTime >= ticksPerCluster)
                : !hasCurrent || block.timestamp - currentTime >= ticksPerCluster

            if startsNew {
                if hasCurrent { clusters.append((currentTime, current, currentKeyframes)) }
                current = Data()
                currentTime = block.timestamp
                currentKeyframes = []
                hasCurrent = true
            }
            guard hasCurrent else { continue }
            if block.track == videoTrack, block.isKeyframe { currentKeyframes.append(block.timestamp) }

            let relative = Int16(clamping: block.timestamp - currentTime)
            current.append(
                element(
                    Matroska.ID.simpleBlock,
                    simpleBlock(
                        track: block.track, relative: relative, isKeyframe: block.isKeyframe,
                        frames: block.frames)))
        }
        if hasCurrent { clusters.append((currentTime, current, currentKeyframes)) }

        // MARK: Kopfteile
        let info = element(
            Matroska.ID.info,
            element(Matroska.ID.timestampScale, unsigned(header.timestampScale))
                + (omitDuration ? Data() : element(Matroska.ID.duration, float(header.duration ?? 0))))
        let tracks = element(Matroska.ID.tracks, header.tracks.map(entry(for:)).joined())

        // **The index gets fixed field widths**, so that its length
        // is known before the positions it points to are calculated.
        // Otherwise every number would depend on the length of the number.
        let placeholder = seekHead(info: 0, tracks: 0, cues: 0)
        let infoAt = placeholder.count
        let tracksAt = infoAt + info.count
        var clusterAt = tracksAt + tracks.count

        var clusterData = Data()
        var cuePoints: [(time: Int64, position: Int)] = []
        for cluster in clusters {
            // One seek point per keyframe, like mkvmerge — it points to
            // the cluster in which the picture lies.
            if clustersAtKeyframes {
                cuePoints.append((cluster.time, clusterAt))
            } else {
                for keyframe in cluster.keyframes { cuePoints.append((keyframe, clusterAt)) }
            }
            let body =
                element(Matroska.ID.clusterTimestamp, unsigned(UInt64(cluster.time)))
                + cluster.body
            let whole = element(Matroska.ID.cluster, body)
            clusterData.append(whole)
            clusterAt += whole.count
        }

        let cues = element(
            Matroska.ID.cues,
            cuePoints.map { point in
                element(
                    Matroska.ID.cuePoint,
                    element(Matroska.ID.cueTime, unsigned(UInt64(point.time)))
                        + element(
                            Matroska.ID.cueTrackPositions,
                            element(Matroska.ID.cueTrack, unsigned(UInt64(videoTrack)))
                                + element(
                                    Matroska.ID.cueClusterPosition,
                                    unsigned(UInt64(point.position)))))
            }.joined())

        let directory = seekHead(info: infoAt, tracks: tracksAt, cues: clusterAt)
        precondition(directory.count == placeholder.count, "The directory must have the same length")

        let segment = element(Matroska.ID.segment, directory + info + tracks + clusterData + cues)
        return ebmlHeader() + segment
    }

    // MARK: - Bausteine

    /// **Several frames stay in one block.** Writing them individually would be
    /// permissible but wrong: a block carries **one** timestamp, and eight
    /// individual blocks with the same time would put a quarter second of sound onto
    /// the same instant.
    private static func simpleBlock(
        track: Int, relative: Int16, isKeyframe: Bool, frames: [Data]
    ) -> Data {
        var payload = vint(UInt64(track))
        payload.append(UInt8((UInt16(bitPattern: relative) >> 8) & 0xFF))
        payload.append(UInt8(UInt16(bitPattern: relative) & 0xFF))

        guard frames.count > 1 else {
            payload.append(isKeyframe ? 0x80 : 0x00)
            payload.append(frames.first ?? Data())
            return payload
        }

        let equalLength = frames.allSatisfy { $0.count == frames[0].count }
        var flags: UInt8 = isKeyframe ? 0x80 : 0x00
        flags |= equalLength ? 0x04 : 0x02
        payload.append(flags)
        payload.append(UInt8(frames.count - 1))

        if !equalLength {
            // Xiph: every length except the last as a sequence of 255s.
            for frame in frames.dropLast() {
                var remaining = frame.count
                while remaining >= 255 {
                    payload.append(255)
                    remaining -= 255
                }
                payload.append(UInt8(remaining))
            }
        }
        for frame in frames { payload.append(frame) }
        return payload
    }

    private static func seekHead(info: Int, tracks: Int, cues: Int) -> Data {
        func seek(_ id: UInt32, _ position: Int) -> Data {
            element(
                Matroska.ID.seek,
                element(Matroska.ID.seekID, identifier(id))
                    // Feste acht Bytes: siehe oben.
                    + element(Matroska.ID.seekPosition, unsigned(UInt64(position), width: 8)))
        }
        return element(
            Matroska.ID.seekHead,
            seek(Matroska.ID.info, info) + seek(Matroska.ID.tracks, tracks)
                + seek(Matroska.ID.cues, cues))
    }

    private static func entry(for track: Matroska.Track) -> Data {
        var body = element(Matroska.ID.trackNumber, unsigned(UInt64(track.number)))
        body += element(Matroska.ID.trackType, unsigned(rawType(track.kind)))
        body += element(Matroska.ID.codecID, Data(track.codecID.utf8))
        body += element(Matroska.ID.flagDefault, unsigned(track.isDefault ? 1 : 0))
        body += element(Matroska.ID.language, Data(track.language.utf8))
        if let codecPrivate = track.codecPrivate {
            body += element(Matroska.ID.codecPrivate, codecPrivate)
        }
        if let width = track.width, let height = track.height {
            body += element(
                Matroska.ID.video,
                element(Matroska.ID.pixelWidth, unsigned(UInt64(width)))
                    + element(Matroska.ID.pixelHeight, unsigned(UInt64(height))))
        }
        if let rate = track.sampleRate {
            body += element(
                Matroska.ID.audio,
                element(Matroska.ID.samplingFrequency, float(Double(rate)))
                    + element(Matroska.ID.channels, unsigned(UInt64(track.channels ?? 2))))
        }
        return element(Matroska.ID.trackEntry, body)
    }

    private static func rawType(_ kind: Matroska.TrackKind) -> UInt64 {
        switch kind {
        case .video: 1
        case .audio: 2
        case .subtitle: 17
        case .other(let value): UInt64(value)
        }
    }

    private static func ebmlHeader() -> Data {
        element(
            Matroska.ID.ebml,
            element(0x4286, unsigned(1)) + element(0x42F7, unsigned(1))
                + element(0x42F2, unsigned(4)) + element(0x42F3, unsigned(8))
                + element(0x4282, Data("matroska".utf8)) + element(0x4287, unsigned(4))
                + element(0x4285, unsigned(2)))
    }

    // MARK: - EBML schreiben

    static func element(_ id: UInt32, _ content: Data) -> Data {
        identifier(id) + vint(UInt64(content.count)) + content
    }

    /// Identifiers already carry their marker and go as they are.
    static func identifier(_ id: UInt32) -> Data {
        var bytes: [UInt8] = []
        var value = id
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return Data(bytes)
    }

    /// A length or number of variable width, with marker bit.
    static func vint(_ value: UInt64) -> Data {
        var width = 1
        while width < 8, value >= (UInt64(1) << UInt64(7 * width)) - 1 { width += 1 }

        var bytes = [UInt8](repeating: 0, count: width)
        var remaining = value
        for index in stride(from: width - 1, through: 0, by: -1) {
            bytes[index] = UInt8(remaining & 0xFF)
            remaining >>= 8
        }
        bytes[0] |= UInt8(0x80 >> (width - 1))
        return Data(bytes)
    }

    static func unsigned(_ value: UInt64, width: Int? = nil) -> Data {
        var bytes: [UInt8] = []
        var remaining = value
        repeat {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        } while remaining > 0
        while let width, bytes.count < width { bytes.insert(0, at: 0) }
        return Data(bytes)
    }

    static func float(_ value: Double) -> Data {
        withUnsafeBytes(of: value.bitPattern.bigEndian) { Data($0) }
    }
}

extension Array where Element == Data {
    fileprivate func joined() -> Data { reduce(into: Data()) { $0.append($1) } }
}
