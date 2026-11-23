import Foundation

extension VobSubSubtitles {

    /// What the control block says about a display.
    struct Instructions {
        var startDelay: Double = 0
        var stopDelay: Double?
        var colors: [Int] = [0, 1, 2, 3]
        var alphas: [Int] = [0, 15, 15, 15]
        var x1 = 0
        var x2 = 0
        var y1 = 0
        var y2 = 0
        var topField = 0
        var bottomField = 0
        var hasArea = false
        var hasOffsets = false
    }

    /// Turns a display unit into a finished picture.
    static func decode(
        _ unit: Data, at pts: Double, palette: [UInt32],
        canvasWidth: Int, canvasHeight: Int
    ) -> SubtitleImageCue? {
        guard unit.count >= 4 else { return nil }
        let base = unit.startIndex
        let controlStart = Int(unit[base + 2]) << 8 | Int(unit[base + 3])
        guard controlStart + 4 <= unit.count else { return nil }

        guard let plan = instructions(in: unit, from: controlStart) else { return nil }
        guard plan.hasArea, plan.hasOffsets else { return nil }

        let width = plan.x2 - plan.x1 + 1
        let height = plan.y2 - plan.y1 + 1
        // An area that is none — occurs with hide units that carry only one command.
        guard width > 0, height > 0, width <= 4096, height <= 4096 else { return nil }

        guard
            let rgba = pixels(
                in: unit, plan: plan, width: width, height: height, palette: palette)
        else { return nil }

        return SubtitleImageCue(
            start: pts + plan.startDelay,
            end: plan.stopDelay.map { pts + $0 } ?? pts,
            x: plan.x1, y: plan.y1, width: width, height: height,
            canvasWidth: canvasWidth, canvasHeight: canvasHeight,
            rgba: rgba
        )
    }

    /// Reads the command sequences.
    ///
    /// **There are several, chained together.** The first says "show from now on", a
    /// later one "hide now"; each carries its own time and points to the next. Anyone
    /// who reads only the first gets subtitles without end.
    static func instructions(in unit: Data, from start: Int) -> Instructions? {
        var plan = Instructions()
        let base = unit.startIndex
        var offset = start
        var seen = Set<Int>()

        while offset + 4 <= unit.count {
            // A loop in the references would never let the loop finish.
            guard seen.insert(offset).inserted else { break }

            let date = Double(Int(unit[base + offset]) << 8 | Int(unit[base + offset + 1]))
            let next = Int(unit[base + offset + 2]) << 8 | Int(unit[base + offset + 3])
            var cursor = offset + 4

            commands: while cursor < unit.count {
                let command = unit[base + cursor]
                cursor += 1

                switch command {
                case 0x00, 0x01:
                    plan.startDelay = date * controlTick
                case 0x02:
                    plan.stopDelay = date * controlTick
                case 0x03:
                    guard cursor + 2 <= unit.count else { break commands }
                    let first = Int(unit[base + cursor])
                    let second = Int(unit[base + cursor + 1])
                    plan.colors = [first >> 4, first & 0x0F, second >> 4, second & 0x0F]
                    cursor += 2
                case 0x04:
                    guard cursor + 2 <= unit.count else { break commands }
                    let first = Int(unit[base + cursor])
                    let second = Int(unit[base + cursor + 1])
                    plan.alphas = [first >> 4, first & 0x0F, second >> 4, second & 0x0F]
                    cursor += 2
                case 0x05:
                    guard cursor + 6 <= unit.count else { break commands }
                    let b = { (index: Int) -> Int in Int(unit[base + cursor + index]) }
                    // Four values of twelve bits each, densely packed.
                    plan.x1 = b(0) << 4 | b(1) >> 4
                    plan.x2 = (b(1) & 0x0F) << 8 | b(2)
                    plan.y1 = b(3) << 4 | b(4) >> 4
                    plan.y2 = (b(4) & 0x0F) << 8 | b(5)
                    plan.hasArea = true
                    cursor += 6
                case 0x06:
                    guard cursor + 4 <= unit.count else { break commands }
                    plan.topField = Int(unit[base + cursor]) << 8 | Int(unit[base + cursor + 1])
                    plan.bottomField =
                        Int(unit[base + cursor + 2]) << 8 | Int(unit[base + cursor + 3])
                    plan.hasOffsets = true
                    cursor += 4
                case 0x07:
                    // Color change within an area — rare, and without it the subtitle stays
                    // readable. It is skipped via the supplied length so that the rest still lines
                    // up.
                    guard cursor + 2 <= unit.count else { break commands }
                    let length = Int(unit[base + cursor]) << 8 | Int(unit[base + cursor + 1])
                    cursor += max(2, length)
                case 0xFF:
                    break commands
                default:
                    break commands
                }
            }

            // The last sequence points to itself.
            if next == offset || next < start || next + 4 > unit.count { break }
            offset = next
        }
        return plan.hasArea ? plan : nil
    }

    // MARK: - Bildpunkte

    /// Unpacks the run lengths into finished pixels.
    ///
    /// **Two bits per pixel, and the lines arrive interlaced.** What comes from the
    /// DVD is meant for a TV with fields: The even lines are in one block, the odd
    /// ones in a second. Anyone who reads them one after the other gets a picture in
    /// which the upper half is squeezed together and the lower half is missing.
    static func pixels(
        in unit: Data, plan: Instructions, width: Int, height: Int, palette: [UInt32]
    ) -> Data? {
        var rgba = Data(count: width * height * 4)
        var failed = false

        rgba.withUnsafeMutableBytes { buffer in
            guard let out = buffer.bindMemory(to: UInt8.self).baseAddress else {
                failed = true
                return
            }

            for field in 0..<2 {
                var reader = NibbleReader(
                    data: unit, offset: field == 0 ? plan.topField : plan.bottomField)
                var line = field
                var column = 0

                while line < height {
                    guard let run = reader.nextRun() else { break }
                    let length = run.length == 0 ? width - column : run.length
                    let color = palette[
                        min(plan.colors[run.color], palette.count - 1)]
                    let alpha = UInt8(plan.alphas[run.color] * 17)

                    for step in 0..<length where column + step < width {
                        let index = (line * width + column + step) * 4
                        out[index] = UInt8((color >> 16) & 0xFF)
                        out[index + 1] = UInt8((color >> 8) & 0xFF)
                        out[index + 2] = UInt8(color & 0xFF)
                        out[index + 3] = alpha
                    }
                    column += length

                    if column >= width {
                        column = 0
                        line += 2
                        // **Every line begins at a byte boundary.** Without the alignment, from the first
                        // odd line on everything slips by four bits — and the picture turns into
                        // stripes.
                        reader.align()
                    }
                }
            }
        }
        return failed ? nil : rgba
    }

    /// Reads the stream in nibbles — that is how the run lengths are encoded.
    struct NibbleReader {
        let data: Data
        var offset: Int
        var isHigh = true

        init(data: Data, offset: Int) {
            self.data = data
            self.offset = data.startIndex + offset
        }

        mutating func next() -> Int? {
            guard offset < data.endIndex else { return nil }
            let byte = Int(data[offset])
            let value = isHigh ? byte >> 4 : byte & 0x0F
            if isHigh {
                isHigh = false
            } else {
                isHigh = true
                offset += 1
            }
            return value
        }

        mutating func align() {
            if !isHigh {
                isHigh = true
                offset += 1
            }
        }

        /// A run length: up to four nibbles, depending on how long the run is.
        ///
        /// **The length is in the number itself.** If the first value is small, another
        /// nibble follows, and so on — so short runs cost four bits and long ones
        /// sixteen. A run of length zero means "to the end of the line".
        mutating func nextRun() -> (length: Int, color: Int)? {
            guard var value = next() else { return nil }
            if value < 0x04 {
                guard let more = next() else { return nil }
                value = value << 4 | more
                if value < 0x10 {
                    guard let more = next() else { return nil }
                    value = value << 4 | more
                    if value < 0x40 {
                        guard let more = next() else { return nil }
                        value = value << 4 | more
                    }
                }
            }
            return (value >> 2, value & 0x03)
        }
    }
}
