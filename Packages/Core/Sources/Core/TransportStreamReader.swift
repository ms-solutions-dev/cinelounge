import Foundation

/// Reads a transport stream **in flow** — morsel by morsel, without end.
///
/// **The difference from ``TransportStream/payloads(from:pid:)`` is everything.**
/// The existing readers get a block they can survey completely: They may start at
/// the front, stop at the back and search in between. A channel has no back. The
/// bytes arrive in chunks whose boundaries have nothing to do with the boundaries
/// of the format — a packet can arrive spread over three morsels, and the tables
/// that say what is in there at all may come only after the first picture.
///
/// That is why this reader remembers everything it could not yet complete and
/// only hands out what is finished.
///
/// ## What does not happen here
///
/// **Nothing is evaluated.** What is a picture and what is audio is decided by
/// the caller; only delimited PES packets with their timestamp are produced here.
/// That keeps responsibility clean: This class knows the transport stream, not
/// the formats inside it.
public final class TransportStreamReader {

    /// A finished PES packet together with timestamp and origin.
    public struct Piece: Sendable, Equatable {
        public let pid: UInt16
        public let kind: TransportStream.StreamKind
        /// The timestamp in MPEG ticks (90 kHz), **raw** — still with the overflow that
        /// ``StreamClock`` straightens out later.
        public let pts: UInt64?
        /// The decode time, if the stream carries it — only with picture reordering
        /// (B-pictures). Without it the writer dies on backward-jumping times (Sola Sport
        /// Mix, 2026-08-16).
        public let dts: UInt64?
        public let data: Data
    }

    /// What the stream contains according to its tables. Empty until they have been
    /// read.
    public private(set) var inventory = TransportStream.Inventory()

    /// The point from which the remainder is discarded instead of growing further.
    ///
    /// **An emergency brake against a broken source.** A stream with no packet
    /// boundary ever found would let the buffer grow without limit until the TV runs
    /// out of memory — and the viewer would see a crash where a black surface would
    /// be the more honest answer.
    static let maximumBuffer = 4 << 20

    private var buffer = Data()
    /// How far into the buffer reading has progressed.
    ///
    /// **A pointer instead of cutting away.** A channel delivers megabytes per minute;
    /// cutting each processed packet off the front would mean copying the entire rest
    /// for every packet. Instead, cleanup happens rarely and in one go.
    private var cursor = 0
    private var isAligned = false

    private var pmtPID: UInt16?

    /// A packet under construction — one per channel.
    private struct Assembly {
        var pts: UInt64?
        var dts: UInt64?
        var data = Data()
        var hasStarted = false
    }
    private var assemblies: [UInt16: Assembly] = [:]

    public init() {}

    // MARK: - Lesen

    /// Takes the next morsel and hands out what it completed.
    private var continuity: [UInt16: UInt8] = [:]
    /// How often the continuity counter of a PID has jumped — packets lost at the
    /// provider.
    public private(set) var continuityErrors = 0
    /// How often a packet under construction grew beyond ``maximumBuffer`` and was
    /// discarded.
    ///
    /// **The emergency brake used to apply only to the read buffer** (repackager
    /// review B9, 2026-09-27): A PES that is never followed by a new packet boundary
    /// grew without an upper limit per channel — to 5.4 MB in the test stream, in the
    /// broken stream until memory runs out. It is now discarded and counted; the next
    /// packet start begins cleanly.
    public private(set) var discardedOversize = 0

    public func read(_ chunk: Data) -> [Piece] {
        buffer.append(chunk)

        var pieces: [Piece] = []
        while true {
            if !isAligned {
                guard let offset = alignment() else { break }
                cursor += offset
                isAligned = true
            }
            guard buffer.count - cursor >= TransportStream.packetSize else { break }

            let start = buffer.startIndex + cursor
            guard buffer[start] == TransportStream.syncByte else {
                // Alignment is lost — search again from here instead of guessing.
                isAligned = false
                cursor += 1
                continue
            }

            let packet = Data(buffer[start..<(start + TransportStream.packetSize)])
            cursor += TransportStream.packetSize
            if let piece = consume(packet) { pieces.append(piece) }
        }

        compact()
        return pieces
    }

    /// Hands out what is still under construction.
    ///
    /// **For the end of a finite stream** — a recording, a file. For a channel this is
    /// never called; there is no last packet there.
    public func flush() -> [Piece] {
        let pending = assemblies.compactMap { pid, assembly -> Piece? in
            finish(pid: pid, assembly)
        }
        assemblies.removeAll()

        // **Ordered by time, not by chance.** What is left lying around here comes from a
        // dictionary, and its order is no order. Two runs over the same bytes would
        // yield two orders — and anyone who passes picture and audio on interleaved then
        // passes them on one way one time and another way the next.
        return pending.sorted {
            ($0.pts ?? .max, $0.pid) < ($1.pts ?? .max, $1.pid)
        }
    }

    // MARK: - Innen

    /// Looks for the next packet boundary from the pointer.
    ///
    /// **A single `0x47` is not sufficient** — the byte occurs constantly in picture
    /// data. Only a second one 188 bytes later is the proof. Unlike when reading a
    /// finished block, this **waits** if the confirmation is not there yet: For a
    /// channel, "not yet arrived" is the normal case, not the end.
    private func alignment() -> Int? {
        let available = buffer.count - cursor
        guard available >= 2 * TransportStream.packetSize else { return nil }

        let base = buffer.startIndex + cursor
        let limit = available - 2 * TransportStream.packetSize
        var offset = 0
        while offset <= limit {
            if buffer[base + offset] == TransportStream.syncByte,
                buffer[base + offset + TransportStream.packetSize] == TransportStream.syncByte
            {
                return offset
            }
            offset += 1
        }
        // Nothing found: What can certainly no longer be a boundary may go.
        cursor += max(0, limit + 1)
        return nil
    }

    /// Clears away the part that has been read — rarely and in one go.
    private func compact() {
        guard cursor > 0 else { return }
        if cursor >= buffer.count {
            buffer.removeAll(keepingCapacity: true)
            cursor = 0
        } else if cursor > TransportStream.packetSize * 512 {
            buffer.removeFirst(cursor)
            cursor = 0
        }

        // The emergency brake: If the remainder grows beyond all measure, the source is
        // broken.
        if buffer.count - cursor > Self.maximumBuffer {
            buffer.removeAll(keepingCapacity: true)
            cursor = 0
            isAligned = false
        }
    }

    /// Processes a single packet and returns what it completed.
    private func consume(_ packet: Data) -> Piece? {
        let pid = TransportStream.pid(of: packet)

        // **The tables are read again and again, not just once.** A channel repeats them
        // every second, and when joining in the middle of the stream the first encounter
        // is often a repetition — anyone who stops after the first find never notices a
        // change in the program.
        if pid == TransportStream.patPID {
            if let found = TransportStream.firstProgramPID(inPAT: TransportStream.payload(of: packet)) {
                pmtPID = found
            }
            return nil
        }
        if let pmtPID, pid == pmtPID {
            let streams = TransportStream.streams(inPMT: TransportStream.payload(of: packet))
            if !streams.isEmpty { inventory.streams = streams }
            return nil
        }

        guard let kind = inventory.streams.first(where: { $0.pid == pid })?.kind else { return nil }

        // Without copying the whole packet — see ``TransportStream/byte(_:_:)``
        // (AP7 · L3).
        // **Continuity counter** (measuring point 2026-09-04): Every packet of a PID carries
        // a counter 0–15; if a packet is missing at the provider, it jumps. It is
        // counted, not interpreted — the number appears in the timestamp report.
        let cc = TransportStream.byte(packet, 3) & 0x0F
        if let last = continuity[pid], (TransportStream.byte(packet, 3) & 0x10) != 0,
            (last &+ 1) & 0x0F != cc, last != cc
        {
            continuityErrors += 1
        }
        continuity[pid] = cc

        var payloadStart = 4
        if (TransportStream.byte(packet, 3) & 0x20) != 0 {
            payloadStart = 5 + Int(TransportStream.byte(packet, 4))
        }
        guard (TransportStream.byte(packet, 3) & 0x10) != 0, payloadStart < packet.count
        else { return nil }

        let chunk = Array(packet[(packet.startIndex + payloadStart)...])
        var finished: Piece?

        // **Do not take out, modify, put back — modify in place.**
        //
        // Here there was `var assembly = assemblies[pid] ?? Assembly()`, and exactly
        // this line made the assembly **quadratic**: The copy raised the buffer's
        // reference count to two, so every `append` re-allocated the entire picture
        // collected so far. A packet carries 184 bytes; a picture of 143 KB thus cost
        // 56 MB of copying, a UHD keyframe of 500 KB around **679 MB — about 226 ms of
        // standstill** on the connection's delivery thread, during which nothing is
        // received.
        //
        // Measured on the real capture `a2.ts` (check agent 2026-08-23):
        //
        // ```
        //                        -Onone     -O
        //   before              12.01      8.05   ms per MB
        //   with this line       6.19      1.68   ms per MB
        //   hand-written,
        //   with pointers        9.87      6.57   ms per MB
        // ```
        //
        // Access via the index beats hand-optimized pointer code by a factor of four —
        // the copy **was** the work. `subscript(_:default:)` reaches through via
        // `_modify`, the buffer stays singly owned, and `append` appends.
        if (TransportStream.byte(packet, 1) & 0x40) != 0 {
            // A new packet begins — the previous one is thereby complete.
            if let previous = assemblies[pid] {
                finished = finish(pid: pid, previous, kind: kind)
            }

            var fresh = Assembly()
            fresh.hasStarted = true
            fresh.pts = SampleAssembly.presentationTimestamp(inPESHeader: Data(chunk))
            fresh.dts = SampleAssembly.decodingTimestamp(inPESHeader: Data(chunk))
            assemblies[pid] = fresh

            if chunk.count > 8, chunk[0] == 0, chunk[1] == 0, chunk[2] == 1 {
                let skip = 9 + Int(chunk[8])
                if skip <= chunk.count {
                    assemblies[pid, default: Assembly()].data.append(contentsOf: chunk[skip...])
                }
            }
        } else if assemblies[pid]?.hasStarted == true {
            assemblies[pid, default: Assembly()].data.append(contentsOf: chunk)
        }
        if (assemblies[pid]?.data.count ?? 0) > Self.maximumBuffer {
            assemblies[pid] = nil
            discardedOversize += 1
        }

        return finished
    }

    private func finish(
        pid: UInt16,
        _ assembly: Assembly,
        kind: TransportStream.StreamKind? = nil
    ) -> Piece? {
        guard assembly.hasStarted, !assembly.data.isEmpty else { return nil }
        guard let kind = kind ?? inventory.streams.first(where: { $0.pid == pid })?.kind
        else { return nil }

        return Piece(pid: pid, kind: kind, pts: assembly.pts, dts: assembly.dts, data: assembly.data)
    }
}
