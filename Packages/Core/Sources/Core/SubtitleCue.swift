import Foundation

/// A subtitle line with its time window.
///
/// **Why the app draws itself:** the subtitle path via the server's main
/// playlist is broken twice over on Dolby Vision titles (wrong codec
/// declaration, transcoding fallbacks) and could be neither turned off on the
/// server side nor repaired on the client side — both proven on the device on
/// 05./2026-08-06. So the app fetches the text itself and lays it over the
/// picture: that works identically on every title type, a switch no longer
/// needs a rebuild, and the display settings take effect immediately.
public struct SubtitleCue: Sendable, Equatable {

    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    /// At which height the line stands. See ``SubtitlePlacement``.
    ///
    /// For text without layout — SRT, WebVTT — always at the bottom; only ASS
    /// brings any indication at all.
    public var placement: SubtitlePlacement

    public init(
        start: TimeInterval, end: TimeInterval, text: String,
        placement: SubtitlePlacement = .bottom
    ) {
        self.start = start
        self.end = end
        self.text = text
        self.placement = placement
    }
}

/// Reads WebVTT as Jellyfin produces it from embedded tracks.
///
/// Deliberately not a complete WebVTT reader: regions, styles and position
/// settings are discarded — drawing is uniformly bottom centre, according to
/// the viewer's settings. What counts are times and text.
public enum WebVTTSubtitles {

    public static func parse(_ raw: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        var pendingWindow: (start: TimeInterval, end: TimeInterval)?
        var pendingLines: [String] = []

        func flush() {
            if let window = pendingWindow, !pendingLines.isEmpty {
                cues.append(
                    SubtitleCue(
                        start: window.start,
                        end: window.end,
                        text: pendingLines.joined(separator: "\n")
                    )
                )
            }
            pendingWindow = nil
            pendingLines = []
        }

        // Otherwise the byte order mark sticks to the first word.
        let text = raw.replacingOccurrences(of: "\u{FEFF}", with: "")

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.isEmpty {
                flush()
                continue
            }

            if line.contains("-->") {
                flush()
                let parts = line.components(separatedBy: "-->")
                guard parts.count == 2,
                    let start = timestamp(parts[0]),
                    // After the end time there are often display hints
                    // (`region:… line:…`) — only the first word is the time.
                    let end = timestamp(
                        parts[1].trimmingCharacters(in: .whitespaces)
                            .components(separatedBy: " ").first ?? ""
                    )
                else { continue }
                pendingWindow = (start, end)
                continue
            }

            // Header, identifiers above the times, regions and notes carry no text:
            // everything before the first time window is skipped.
            guard pendingWindow != nil else { continue }
            pendingLines.append(clean(line))
        }
        flush()

        return cues.sorted { $0.start < $1.start }
    }

    /// `HH:MM:SS.mmm` or `MM:SS.mmm` in seconds.
    static func timestamp(_ raw: String) -> TimeInterval? {
        let parts = raw.trimmingCharacters(in: .whitespaces).components(separatedBy: ":")
        guard parts.count == 2 || parts.count == 3 else { return nil }

        var seconds: TimeInterval = 0
        for part in parts {
            guard let value = TimeInterval(part.replacingOccurrences(of: ",", with: ".")) else {
                return nil
            }
            seconds = seconds * 60 + value
        }
        return seconds
    }

    /// Removes markup (`<i>`, `<b>`, speaker brackets) and resolves the common
    /// character entities — plain text is drawn.
    static func clean(_ line: String) -> String {
        var result = line.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )
        for (entity, character) in [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&nbsp;", "\u{00A0}"), ("&quot;", "\""), ("&#39;", "'"),
        ] {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        return result
    }
}

extension [SubtitleCue] {

    /// How long a line stays at most.
    ///
    /// The search needs it to know how far back it must look: lines are ordered
    /// by their **start**, and one that began earlier may still be showing.
    /// Thirty seconds is generous — a song lyric holds that long, a dialogue
    /// never.
    static let longestCue: TimeInterval = 30

    /// All lines showing at this position, separated by height.
    ///
    /// **Unlike with plain text, more than one can apply.** ASS layers dialogue
    /// and signs on top of each other; whoever takes only the first loses,
    /// depending on the order, sometimes the one and sometimes the other.
    public func lines(at position: TimeInterval) -> [SubtitlePlacement: String] {
        var found: [SubtitlePlacement: [String]] = [:]

        var index = firstIndex(startingAfter: position - Self.longestCue)
        while index < count, self[index].start <= position {
            let cue = self[index]
            if cue.end > position { found[cue.placement, default: []].append(cue.text) }
            index += 1
        }
        return found.mapValues { $0.joined(separator: "\n") }
    }

    /// The first line that did not begin before this time — found by binary
    /// search.
    func firstIndex(startingAfter time: TimeInterval) -> Int {
        var low = 0
        var high = count
        while low < high {
            let middle = (low + high) / 2
            if self[middle].start < time { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// The text for the position, or `nil` between two lines.
    ///
    /// Binary search: a film carries thousands of lines, and the question runs at
    /// the pace of playback.
    public func text(at position: TimeInterval) -> String? {
        var low = 0
        var high = count - 1
        while low <= high {
            let middle = (low + high) / 2
            let cue = self[middle]
            if position < cue.start {
                high = middle - 1
            } else if position >= cue.end {
                low = middle + 1
            } else {
                return cue.text
            }
        }
        return nil
    }
}
