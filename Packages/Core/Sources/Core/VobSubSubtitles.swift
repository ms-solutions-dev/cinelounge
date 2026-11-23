import Foundation

/// Reads VobSub — the subtitles of the DVD.
///
/// **428 tracks in the catalog, and to this day the reason for the second
/// engine.** Unlike PGS they cannot be converted to text, and unlike ASS they have
/// no layout but are simply pictures.
///
/// ## What the server provides — and what was wrong in the notes
///
/// The roadmap said DVD picture formats could be "neither converted nor delivered
/// raw; every request ends immediately in an error". The first is true: The server
/// answers `.vtt` with 400. The second is not — **it delivers `.sub` without
/// complaint** (re-measured on 2026-08-10: 92 kilobytes for one track). Only the
/// associated `.idx` it refuses, and that carries the color table.
///
/// ## The structure
///
/// The `.sub` is an MPEG program stream as it comes from the DVD: pack headers,
/// in between PES packets of the "private" stream, in them substreams from `0x20`
/// on — one per subtitle language. A display unit (SPU) begins with its total
/// length and can span several packets; the time is in the first of them.
///
/// In the unit itself: run-length-encoded pixels with **two bits** per pixel, then
/// a control block with commands — when to show, when to hide, which area, which
/// four colors from the table, how transparent.
public enum VobSubSubtitles {

    /// The clock of the DVD timestamps — 90 kHz, as with the transport stream.
    static let timescale: Double = 90000
    /// The clock **within** the control block: 1024 steps per 90 kHz tick.
    static let controlTick: Double = 1024 / 90000

    /// The four colors when the table is missing.
    ///
    /// **A reasoned stopgap, not arbitrariness.** The color table is in the `.idx`,
    /// which the server does not hand out; in the file itself it is in the track
    /// header (see ``Matroska/Track/vobSubIndex``). Where both are missing, the
    /// allocation applies by which DVDs have always been designed: background, text,
    /// outline, anti-aliasing. White text with a black outline is the choice on nearly
    /// every disc — and where it is not, the subtitle stays readable instead of
    /// invisible.
    public static let defaultPalette: [UInt32] =
        [
            0x0000_0000,  // Hintergrund
            0x00FF_FFFF,  // Schrift
            0x0000_0000,  // Umriss
            0x0080_8080,  // anti-aliasing
        ] + Array(repeating: 0x00FF_FFFF, count: 12)

    /// The canvases that are inferred when the setting is missing.
    ///
    /// **In order from small to large**, the first one that fits all areas is taken.
    /// Guessing too small would mean cut-off text, guessing too large unreadably small
    /// text — and the areas of a track rarely reach to the edge, so the result is
    /// rounded up and not averaged.
    static let commonCanvases = [(720, 480), (720, 576), (1280, 720), (1920, 1080), (3840, 2160)]

    /// Reads an entire track.
    ///
    /// - Parameters:
    ///   - palette: The 16 colors from the `.idx` or the track header, as
    ///     `0x00RRGGBB`. If missing, ``defaultPalette`` applies.
    ///   - canvasWidth: The canvas to which the area values refer. If missing, it is
    ///     inferred — see ``commonCanvases``.
    public static func parse(
        _ data: Data,
        palette: [UInt32]? = nil,
        canvasWidth: Int? = nil,
        canvasHeight: Int? = nil
    ) -> [SubtitleImageCue] {
        let colors = (palette?.count ?? 0) >= 16 ? palette! : defaultPalette
        var cues: [SubtitleImageCue] = []

        for unit in units(in: data) {
            guard
                let cue = decode(
                    unit.data, at: unit.pts, palette: colors,
                    canvasWidth: canvasWidth ?? 0, canvasHeight: canvasHeight ?? 0)
            else { continue }
            cues.append(cue)
        }

        // **The size of the canvas is in the `.idx`, which the server does not hand
        // out.** If it is missing, it is inferred from the areas: The test material
        // reaches up to 1443×975 — so it is not DVD-sized but set for 1920×1080. Anyone
        // who assumes 720×576 here draws the text enlarged to double across the picture.
        if canvasWidth == nil || canvasHeight == nil {
            let widest = cues.map { $0.x + $0.width }.max() ?? 0
            let tallest = cues.map { $0.y + $0.height }.max() ?? 0
            let fitting = commonCanvases.first { $0.0 >= widest && $0.1 >= tallest }
            for index in cues.indices {
                cues[index].canvasWidth = canvasWidth ?? fitting?.0 ?? max(widest, 1)
                cues[index].canvasHeight = canvasHeight ?? fitting?.1 ?? max(tallest, 1)
            }
        }

        // **A subtitle without a hide command stays until the next one.** That happens
        // and is permitted; without this fix-up a line would stand for a tenth of a
        // second and vanish.
        for index in cues.indices where cues[index].end <= cues[index].start {
            let next = index + 1 < cues.count ? cues[index + 1].start : cues[index].start + 5
            cues[index].end = next
        }
        return cues.sorted { $0.start < $1.start }
    }

    // MARK: - Programmstrom

    struct Unit {
        let pts: Double
        let data: Data
    }

    /// Extracts the display units from the program stream.
    ///
    /// **A unit can span several packets** — the first test track distributes 4403
    /// bytes over three. Its length is in the first two bytes; until that is reached,
    /// data is appended.
    static func units(in data: Data) -> [Unit] {
        var units: [Unit] = []
        var pending = Data()
        var pendingPTS: Double?
        var expected = 0
        var offset = data.startIndex

        func finish() {
            if let pts = pendingPTS, !pending.isEmpty {
                units.append(Unit(pts: pts, data: pending))
            }
            pending = Data()
            pendingPTS = nil
            expected = 0
        }

        while offset + 4 <= data.endIndex {
            guard data[offset] == 0, data[offset + 1] == 0, data[offset + 2] == 1 else {
                offset += 1
                continue
            }
            let marker = data[offset + 3]

            // Pack header: fourteen bytes plus stuffing, then it carries on.
            if marker == 0xBA {
                guard offset + 14 <= data.endIndex else { break }
                offset += 14 + Int(data[offset + 13] & 0x07)
                continue
            }
            // We skip everything except the private stream — the length is in the header, so
            // skipping is unambiguous as well.
            guard offset + 9 <= data.endIndex else { break }
            let length = Int(data[offset + 4]) << 8 | Int(data[offset + 5])
            guard length > 3, offset + 6 + length <= data.endIndex else { break }

            guard marker == 0xBD else {
                offset += 6 + length
                continue
            }

            let flags = data[offset + 7]
            let headerLength = Int(data[offset + 8])
            var pts: Double?
            if flags & 0x80 != 0, offset + 14 <= data.endIndex {
                pts = Double(timestamp(at: offset + 9, in: data)) / timescale
            }

            let bodyStart = offset + 9 + headerLength
            let bodyEnd = offset + 6 + length
            offset = bodyEnd
            guard bodyStart < bodyEnd else { continue }

            // The first byte names the substream: `0x20` and higher are subtitles, one per
            // language.
            let stream = data[bodyStart]
            guard stream & 0xE0 == 0x20 else { continue }
            let body = data.subdata(in: (bodyStart + 1)..<bodyEnd)

            if pts != nil {
                finish()
                pendingPTS = pts
                expected =
                    body.count >= 2
                    ? Int(body[body.startIndex]) << 8 | Int(body[body.startIndex + 1]) : 0
            }
            guard pendingPTS != nil else { continue }
            pending.append(body)
            if expected > 0, pending.count >= expected { finish() }
        }
        finish()
        return units
    }

    /// The 33 bits of a timestamp, spread across five bytes.
    static func timestamp(at offset: Int, in data: Data) -> UInt64 {
        let byte = { (index: Int) -> UInt64 in UInt64(data[offset + index]) }
        var value = ((byte(0) & 0x0E) >> 1) << 30
        value |= byte(1) << 22
        value |= ((byte(2) & 0xFE) >> 1) << 15
        value |= byte(3) << 7
        value |= (byte(4) & 0xFE) >> 1
        return value
    }
}
