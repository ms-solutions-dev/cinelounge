import Foundation

/// An image subtitle with its time window — position and dimensions in the
/// coordinates of the canvas that the track itself names (for Blu-ray 1920×1080).
///
/// The pixels are present as finished RGBA (four bytes per pixel, row by row): `Core`
/// knows no drawing frameworks, the conversion into a system image is done by the
/// view. Decoding happens at reading and not at drawing — a track has a few hundred
/// images, and the question "what is on?" runs in step with the clock.
public struct SubtitleImageCue: Sendable, Equatable {

    public var start: TimeInterval
    public var end: TimeInterval
    /// Position of the top left corner on the canvas.
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    /// The canvas to which position and dimensions refer.
    public var canvasWidth: Int
    public var canvasHeight: Int
    /// Zeilenweise RGBA-Pixel, `width * height * 4` Bytes.
    public var rgba: Data

    public init(
        start: TimeInterval, end: TimeInterval,
        x: Int, y: Int, width: Int, height: Int,
        canvasWidth: Int, canvasHeight: Int, rgba: Data
    ) {
        self.start = start
        self.end = end
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.rgba = rgba
    }
}

/// Reads PGS subtitles (`.sup`) as they come from Blu-rays and as the server
/// delivers them raw as `Stream.pgssub`.
///
/// **Why the app reads them itself:** image subtitles cannot be converted to text —
/// the server permanently answers the VTT request with an error (proven: Kliasou
/// Magla, 2026-08-07). The detour via VLC is discarded: the engine switch in the middle
/// of playback was the most unstable spot of the app. Instead this reader decodes
/// the bitmaps, and the custom subtitle renderer lays them over the picture — the
/// same path as with text, only with images instead of lines.
///
/// The format in brief: a stream of segments, each begins with "PG", a timestamp
/// (90 kHz clock) and the type. A display unit consists of composition (PCS),
/// windows (WDS), palette (PDS) and objects (ODS, run-length encoded, if need be
/// chunked over several segments) and ends with an END segment. A composition
/// **without** objects fades out — it delivers the end of the running window.
public enum PGSSubtitles {

    public static func parse(_ data: Data) -> [SubtitleImageCue] {
        let bytes = [UInt8](data)
        var cues: [SubtitleImageCue] = []

        // Palettes and objects apply until they are overwritten — objects can be chunked
        // over several ODS segments and are decoded only at the end of the display unit.
        var palettes: [UInt8: [UInt8: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)]] = [:]
        var objects: [UInt16: (width: Int, height: Int, rle: [UInt8])] = [:]

        struct PendingComposition {
            var pts: TimeInterval
            var canvasWidth: Int
            var canvasHeight: Int
            var paletteID: UInt8
            var placements: [(objectID: UInt16, x: Int, y: Int)]
        }
        var pending: PendingComposition?
        /// The windows currently in the picture — closed by the next composition.
        var open: [SubtitleImageCue] = []

        func closeOpen(at time: TimeInterval) {
            guard !open.isEmpty else { return }
            for var cue in open {
                cue.end = time
                // Windows without duration arise when two compositions carry the same timestamp —
                // they would be invisible.
                if cue.end > cue.start { cues.append(cue) }
            }
            open = []
        }

        var offset = 0
        while offset + 13 <= bytes.count {
            // Header: "PG", PTS (4), DTS (4), type (1), length (2).
            guard bytes[offset] == 0x50, bytes[offset + 1] == 0x47 else { break }
            let pts =
                TimeInterval(
                    UInt32(bytes[offset + 2]) << 24 | UInt32(bytes[offset + 3]) << 16
                        | UInt32(bytes[offset + 4]) << 8 | UInt32(bytes[offset + 5])
                ) / 90_000
            let kind = bytes[offset + 10]
            let length = Int(bytes[offset + 11]) << 8 | Int(bytes[offset + 12])
            let body = offset + 13
            guard body + length <= bytes.count else { break }

            switch kind {
            case 0x16:  // Zusammenstellung (PCS)
                guard length >= 11 else { break }
                let canvasWidth = Int(bytes[body]) << 8 | Int(bytes[body + 1])
                let canvasHeight = Int(bytes[body + 2]) << 8 | Int(bytes[body + 3])
                let paletteID = bytes[body + 9]
                let objectCount = Int(bytes[body + 10])

                var placements: [(UInt16, Int, Int)] = []
                var cursor = body + 11
                for _ in 0..<objectCount {
                    guard cursor + 8 <= body + length else { break }
                    let objectID = UInt16(bytes[cursor]) << 8 | UInt16(bytes[cursor + 1])
                    let cropped = bytes[cursor + 3] & 0x80 != 0
                    let x = Int(bytes[cursor + 4]) << 8 | Int(bytes[cursor + 5])
                    let y = Int(bytes[cursor + 6]) << 8 | Int(bytes[cursor + 7])
                    placements.append((objectID, x, y))
                    // A cropped object carries four further dimension fields.
                    cursor += cropped ? 16 : 8
                }

                // Every new composition ends the running display —
                // also the empty one that comes only to fade out.
                closeOpen(at: pts)
                pending =
                    placements.isEmpty
                    ? nil
                    : PendingComposition(
                        pts: pts,
                        canvasWidth: canvasWidth,
                        canvasHeight: canvasHeight,
                        paletteID: paletteID,
                        placements: placements
                    )

            case 0x14:  // Palette (PDS)
                guard length >= 2 else { break }
                let paletteID = bytes[body]
                var entries = palettes[paletteID] ?? [:]
                var cursor = body + 2
                while cursor + 5 <= body + length {
                    let id = bytes[cursor]
                    entries[id] = Self.rgba(
                        y: bytes[cursor + 1],
                        cr: bytes[cursor + 2],
                        cb: bytes[cursor + 3],
                        alpha: bytes[cursor + 4]
                    )
                    cursor += 5
                }
                palettes[paletteID] = entries

            case 0x15:  // Object (ODS), if need be chunked
                guard length >= 4 else { break }
                let objectID = UInt16(bytes[body]) << 8 | UInt16(bytes[body + 1])
                let sequence = bytes[body + 3]
                if sequence & 0x80 != 0 {
                    // First chunk: after the data length (3 bytes) come the dimensions.
                    guard length >= 11 else { break }
                    let width = Int(bytes[body + 7]) << 8 | Int(bytes[body + 8])
                    let height = Int(bytes[body + 9]) << 8 | Int(bytes[body + 10])
                    objects[objectID] = (width, height, Array(bytes[(body + 11)..<(body + length)]))
                } else {
                    objects[objectID]?.rle.append(contentsOf: bytes[(body + 4)..<(body + length)])
                }

            case 0x80:  // End of the display unit — now it is decoded.
                if let composition = pending {
                    let palette = palettes[composition.paletteID] ?? [:]
                    for placement in composition.placements {
                        guard let object = objects[placement.objectID],
                            object.width > 0, object.height > 0,
                            let pixels = Self.decode(
                                rle: object.rle,
                                width: object.width,
                                height: object.height,
                                palette: palette
                            )
                        else { continue }
                        open.append(
                            SubtitleImageCue(
                                start: composition.pts,
                                // Provisionally open — closed by the next composition; the margin at the bottom
                                // catches tracks whose last fade-out is missing.
                                end: composition.pts + Self.fallbackDuration,
                                x: placement.x,
                                y: placement.y,
                                width: object.width,
                                height: object.height,
                                canvasWidth: composition.canvasWidth,
                                canvasHeight: composition.canvasHeight,
                                rgba: pixels
                            )
                        )
                    }
                    pending = nil
                }

            default:
                break  // Window definitions (0x17) do not need the position.
            }

            offset = body + length
        }

        // What is still open at the end of the stream keeps the fallback duration.
        cues.append(contentsOf: open)

        return cues.sorted { $0.start < $1.start }
    }

    /// Fallback duration for a window whose fade-out is missing in the stream.
    static let fallbackDuration: TimeInterval = 8

    /// BT.709, as belongs to Blu-ray material — the source of these tracks.
    static func rgba(
        y: UInt8, cr: UInt8, cb: UInt8, alpha: UInt8
    ) -> (
        r: UInt8, g: UInt8, b: UInt8, a: UInt8
    ) {
        let y = Double(y) - 16
        let cr = Double(cr) - 128
        let cb = Double(cb) - 128
        func clamp(_ value: Double) -> UInt8 { UInt8(max(0, min(255, value.rounded()))) }
        return (
            r: clamp(1.164 * y + 1.793 * cr),
            g: clamp(1.164 * y - 0.534 * cr - 0.213 * cb),
            b: clamp(1.164 * y + 2.115 * cb),
            a: alpha
        )
    }

    /// The run-length decoding of the PGS format.
    ///
    /// A byte not equal to zero is a single pixel of its color. Zero introduces: another
    /// zero means end of line; otherwise the top two bits of the following byte say
    /// whether a short or long run follows and whether it carries color zero or a named
    /// color.
    static func decode(
        rle: [UInt8],
        width: Int,
        height: Int,
        palette: [UInt8: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)]
    ) -> Data? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var x = 0
        var row = 0
        var cursor = 0

        func paint(_ color: UInt8, count: Int) {
            guard row < height else { return }
            let entry = palette[color] ?? (0, 0, 0, 0)
            let limit = min(count, width - x)
            var index = (row * width + x) * 4
            for _ in 0..<max(0, limit) {
                pixels[index] = entry.r
                pixels[index + 1] = entry.g
                pixels[index + 2] = entry.b
                pixels[index + 3] = entry.a
                index += 4
            }
            x += max(0, limit)
        }

        while cursor < rle.count, row < height {
            let first = rle[cursor]
            cursor += 1
            if first != 0 {
                paint(first, count: 1)
                continue
            }
            guard cursor < rle.count else { break }
            let control = rle[cursor]
            cursor += 1
            if control == 0 {
                // End of line — even if the line was shorter than the width.
                row += 1
                x = 0
                continue
            }
            switch control >> 6 {
            case 0b00:
                paint(0, count: Int(control & 0x3F))
            case 0b01:
                guard cursor < rle.count else { return nil }
                paint(0, count: Int(control & 0x3F) << 8 | Int(rle[cursor]))
                cursor += 1
            case 0b10:
                guard cursor < rle.count else { return nil }
                paint(rle[cursor], count: Int(control & 0x3F))
                cursor += 1
            default:
                guard cursor + 1 < rle.count else { return nil }
                let count = Int(control & 0x3F) << 8 | Int(rle[cursor])
                paint(rle[cursor + 1], count: count)
                cursor += 2
            }
        }

        return Data(pixels)
    }
}

extension [SubtitleImageCue] {

    /// The images for the position — several if a composition carries several windows
    /// (for instance speakers at the top and bottom at the same time).
    public func images(at position: TimeInterval) -> [SubtitleImageCue] {
        filter { position >= $0.start && position < $0.end }
    }
}
