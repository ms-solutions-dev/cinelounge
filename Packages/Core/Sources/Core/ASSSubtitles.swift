import Foundation

/// Where a subtitle line sits on the picture.
///
/// **The reason ASS is a case of its own at all.** Plain text always sits at the bottom;
/// ASS does not. In anime, the same file carries the dialogue at the bottom and **signs**
/// at the top — translated captions, name tags, chapter cards. Drawing everything at the
/// bottom puts the caption on top of the dialogue and makes both unreadable. That is
/// exactly where the conversion to WebVTT failed, and exactly why ASS used to go to VLC.
public enum SubtitlePlacement: String, Sendable, Equatable, Codable {
    case bottom
    case middle
    case top
}

/// Reads ASS and SSA — the subtitles with layout.
///
/// **Deliberately not a complete renderer.** ASS can do fonts, colors, rotations, karaoke
/// coloring and vector drawings; rebuilding all of that would be a project of its own.
/// What is kept is what makes the difference between "readable" and "unreadable" —
/// **time, text and position** —, everything else is dropped. Drawing then follows the
/// viewer's settings, as with any other subtitle.
///
/// **What is explicitly discarded** instead of half-rendering it: vector drawings (`\p1`).
/// They are not text but shapes — shown as text, columns of numbers appeared in the middle
/// of the picture.
public enum ASSSubtitles {

    public static func parse(_ raw: String) -> [SubtitleCue] {
        var styles: [String: SubtitlePlacement] = [:]
        var styleFormat: [String] = []
        var eventFormat: [String] = []
        var section = ""
        var isLegacy = false
        var cues: [SubtitleCue] = []

        for rawLine in raw.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("[") {
                section = line.lowercased()
                // **SSA counts the positions differently from ASS.** The same number means something
                // different in the two versions; whoever overlooks this pushes the dialogue to the top in
                // old files.
                isLegacy = section.contains("[v4 styles]")
                continue
            }

            guard let colon = line.firstIndex(of: ":") else { continue }
            let keyword = String(line[line.startIndex..<colon]).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(
                in: .whitespaces)

            if section.contains("styles") {
                if keyword == "format" {
                    styleFormat = fields(in: value)
                } else if keyword == "style" {
                    let parts = value.components(separatedBy: ",")
                    guard let name = field("name", in: parts, format: styleFormat),
                        let alignment = field("alignment", in: parts, format: styleFormat)
                            .flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) })
                    else { continue }
                    styles[name.trimmingCharacters(in: .whitespaces)] = placement(
                        alignment, legacy: isLegacy)
                }
                continue
            }

            guard section.contains("events") else { continue }
            if keyword == "format" {
                eventFormat = fields(in: value)
                continue
            }
            // `Comment:` lines are switched off — they do not belong on the picture.
            guard keyword == "dialogue" else { continue }

            // **The text comes last and may contain commas.** That is why the split happens only as
            // often as there are fields before it; everything after is text. Whoever splits blindly at
            // every comma loses every sentence with an enumeration — in the middle of a word, at that.
            let parts = split(value, into: max(eventFormat.count, 1))
            guard let start = field("start", in: parts, format: eventFormat).flatMap(time),
                let end = field("end", in: parts, format: eventFormat).flatMap(time),
                let body = field("text", in: parts, format: eventFormat)
            else { continue }

            let styleName =
                field("style", in: parts, format: eventFormat)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            let fallback = styles[styleName] ?? .bottom
            guard let rendered = text(body, placement: fallback) else { continue }

            cues.append(
                SubtitleCue(
                    start: start, end: end, text: rendered.text, placement: rendered.placement))
        }

        return cues.sorted { $0.start < $1.start }
    }

    // MARK: - Text

    /// Cleans up a dialogue text and reads out the position while doing so.
    ///
    /// `nil` if nothing readable remains — an empty line with a time window would otherwise
    /// cover nothing but itself for two seconds.
    static func text(
        _ raw: String, placement: SubtitlePlacement
    )
        -> (text: String, placement: SubtitlePlacement)?
    {
        var placement = placement
        var result = ""
        var index = raw.startIndex
        var isDrawing = false

        while index < raw.endIndex {
            guard raw[index] == "{" else {
                // **What stands between `\p1` and `\p0` is skipped** — it is coordinates, not text.
                if !isDrawing { result.append(raw[index]) }
                index = raw.index(after: index)
                continue
            }
            guard let close = raw[index...].firstIndex(of: "}") else {
                if !isDrawing { result.append(contentsOf: raw[index...]) }
                break
            }
            let block = String(raw[raw.index(after: index)..<close])
            index = raw.index(after: close)

            if let found = alignment(in: block) { placement = found }
            if let drawing = drawingMode(in: block) { isDrawing = drawing }
        }

        let text = unescape(result).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : (text, placement)
    }

    static func unescape(_ raw: String) -> String {
        raw
            // Hard line break — for `\n` the versions disagree, but a break is defensible in both
            // readings.
            .replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\h", with: "\u{00A0}")
    }

    /// Reads `\an1`–`\an9` or the older `\a`.
    static func alignment(in block: String) -> SubtitlePlacement? {
        if let value = number(after: "\\an", in: block), (1...9).contains(value) {
            return placement(value, legacy: false)
        }
        if let value = number(after: "\\a", in: block), (1...11).contains(value) {
            return placement(value, legacy: true)
        }
        return nil
    }

    static func drawingMode(in block: String) -> Bool? {
        number(after: "\\p", in: block).map { $0 > 0 }
    }

    /// The number directly after a directive.
    static func number(after keyword: String, in block: String) -> Int? {
        guard let range = block.range(of: keyword) else { return nil }
        // `\a` is also contained in `\on` and `\alpha`; only a digit right after it counts.
        var digits = ""
        var index = range.upperBound
        while index < block.endIndex, block[index].isNumber {
            digits.append(block[index])
            index = block.index(after: index)
        }
        return digits.isEmpty ? nil : Int(digits)
    }

    /// Translates a position number into the three heights that are drawn.
    ///
    /// **Left, center, right drop out.** The renderer centers every line; the height is the
    /// difference that counts — it decides whether a sign covers the dialogue.
    static func placement(_ value: Int, legacy: Bool) -> SubtitlePlacement {
        if legacy {
            return switch value {
            case 5, 6, 7: .top
            case 9, 10, 11: .middle
            default: .bottom
            }
        }
        return switch value {
        case 7, 8, 9: .top
        case 4, 5, 6: .middle
        default: .bottom
        }
    }

    // MARK: - Felder

    /// Splits at commas, but at most as often as fields are expected.
    ///
    /// The last piece keeps its commas — and that is exactly what matters: The text comes last,
    /// and sentences with an enumeration are the normal case.
    static func split(_ value: String, into count: Int) -> [String] {
        var parts: [String] = []
        var current = ""
        for character in value {
            if character == ",", parts.count < count - 1 {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        return parts
    }

    static func fields(in line: String) -> [String] {
        line.components(separatedBy: ",").map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }
    }

    /// Fetches a named field — **the order is in the file**, not in the format. SSA and ASS
    /// order differently, and some tools leave fields out; whoever assumes fixed positions reads
    /// the end time as the style in every third file.
    static func field(_ name: String, in parts: [String], format: [String]) -> String? {
        guard let index = format.firstIndex(of: name), index < parts.count else { return nil }
        return parts[index]
    }

    /// `H:MM:SS.cc` — Stunden einstellig, Hundertstel am Ende.
    static func time(_ raw: String) -> TimeInterval? {
        let parts = raw.trimmingCharacters(in: .whitespaces).components(separatedBy: ":")
        guard parts.count == 3 else { return nil }

        var seconds: TimeInterval = 0
        for part in parts {
            guard let value = TimeInterval(part) else { return nil }
            seconds = seconds * 60 + value
        }
        return seconds
    }
}
