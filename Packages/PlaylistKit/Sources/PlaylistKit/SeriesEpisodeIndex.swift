import Core
import Foundation

/// Which series have episodes at the provider at all.
///
/// **The occasion** (viewer finding 2026-08-22: nothing in there that could be played):
/// At the checked provider, **958 of 4974 series — 19.3 % — carry no episode
/// anywhere.** The entry has poster, description and cast,
/// but `get_series_info` returns no `episodes` field, and there are no other paths
/// to them. On screen, such an empty shell cannot be told apart from an app
/// bug.
///
/// **Why from the M3U and not from the interface:** `get_series_info`
/// asks per series and takes 219 ms. For a category with 109 titles that is
/// 24 seconds, for the whole catalog 18 minutes. The M3U brings all 83 269 episodes in **one**
/// fetch — 11 MB, measured 8 seconds. The parsing
/// below costs 21 ms in the release build (M3; on the TV roughly
/// double) and is thus a non-issue.
///
/// **Verified that the M3U is complete:** 4016 series titles are in it,
/// `get_series` knows 4974 — and **zero** episodes in the M3U belong to a
/// title the directory does not know. So it is a true subset and
/// conceals nothing. Additionally 26 series cross-counted: episode count from the
/// interface equals episode count from the M3U, 26 of 26.
public struct SeriesEpisodeIndex: Sendable, Equatable {

    /// The series titles for which at least one episode is in the list.
    public let titles: Set<String>
    public let builtAt: Date

    public init(titles: Set<String>, builtAt: Date) {
        self.titles = titles
        self.builtAt = builtAt
    }

    /// From how many titles on the directory counts as usable at all.
    ///
    /// **The safety belt.** If `get.php` returns an error page, an empty
    /// body or a truncated response, zero or a handful of
    /// titles come out — and without this threshold the whole catalog would suddenly be
    /// "without episodes". Better no marking at all than a wrong one.
    public static let minimumUsable = 100

    public var isUsable: Bool { titles.count >= Self.minimumUsable }

    public func hasEpisodes(_ seriesTitle: String) -> Bool {
        titles.contains(seriesTitle.trimmingCharacters(in: .whitespaces))
    }

    // MARK: - Auswertung

    /// Extracts from an M3U the set of series titles with at least one episode.
    ///
    /// **On bytes and not on strings.** Splitting 11 MB into Swift strings
    /// costs a multiple, and by far the largest part of the lines
    /// is discarded anyway: only the address lines with `/series/` count, and
    /// of their label only the part before " S01 E01" is of interest.
    /// Measured on the real list: 21 ms with `-O`, 357 ms with `-Onone` — and
    /// `device.sh` builds without optimization, so the difference here is not
    /// hair-splitting.
    public static func titles(inPlaylist data: Data) -> Set<String> {
        var found = Set<String>()
        found.reserveCapacity(5000)

        let newline = UInt8(ascii: "\n")
        let hash = UInt8(ascii: "#")

        // The most recently seen label. An M3U is built in pairs:
        // `#EXTINF:…,Name`, below it the address. Only the address reveals whether it is
        // a series episode — the name has to wait until then.
        var pendingLabel: Range<Int>?

        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var lineStart = 0
            var index = 0

            while index <= bytes.count {
                guard index == bytes.count || bytes[index] == newline else {
                    index += 1
                    continue
                }

                var lineEnd = index
                // Carriage return: providers write both line endings.
                if lineEnd > lineStart, bytes[lineEnd - 1] == 13 { lineEnd -= 1 }

                if lineEnd > lineStart {
                    if bytes[lineStart] == hash {
                        pendingLabel = label(bytes, from: lineStart, to: lineEnd)
                    } else if let label = pendingLabel {
                        if isSeriesAddress(bytes, from: lineStart, to: lineEnd) {
                            found.insert(seriesTitle(bytes, in: label))
                        }
                        pendingLabel = nil
                    }
                }

                lineStart = index + 1
                index += 1
            }
        }
        return found
    }

    /// The name from an `#EXTINF` line: everything after the first comma that is
    /// **not inside quotation marks**.
    ///
    /// **Not the last comma** — this mistake was here first and was noticed
    /// when building the test fixture: "Dasiahol, bliadrozia pluslaik ceteheir | TR S01 E01"
    /// would have become "el espía arrepentido | TR", and the title would never have
    /// matched the directory entry. A series name may contain commas,
    /// the structure of the line is `#EXTINF:<duration>[ attributes],<name>`.
    ///
    /// The quotation marks count along so that the same path also copes with `m3u_plus`:
    /// there `tvg-name="SeriesEntry, die"` precedes the name, and the comma
    /// inside it separates nothing.
    private static func label(
        _ bytes: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int
    ) -> Range<Int>? {
        let comma = UInt8(ascii: ",")
        let quote = UInt8(ascii: "\"")
        var inQuotes = false
        var i = start
        while i < end {
            if bytes[i] == quote {
                inQuotes.toggle()
            } else if bytes[i] == comma, !inQuotes {
                return (i + 1) < end ? (i + 1)..<end : nil
            }
            i += 1
        }
        return nil
    }

    /// Only episodes count. Movies are under `/movie/`, channels without a path part.
    private static func isSeriesAddress(
        _ bytes: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int
    ) -> Bool {
        let needle: [UInt8] = Array("/series/".utf8)
        guard end - start >= needle.count else { return false }
        var i = start
        while i <= end - needle.count {
            var j = 0
            while j < needle.count, bytes[i + j] == needle[j] { j += 1 }
            if j == needle.count { return true }
            i += 1
        }
        return false
    }

    /// "Doğu |TR S04 E02" becomes "Doğu |TR".
    ///
    /// The cut is made at the **last** occurrence of " S" plus a digit: a title
    /// may itself contain something like that ("Giflaun Dialiavel S1"), and then
    /// the later spot wins — the season marker is always at the end.
    /// If none is found, the name stays unchanged; series without
    /// season structure exist.
    private static func seriesTitle(
        _ bytes: UnsafeBufferPointer<UInt8>, in range: Range<Int>
    ) -> String {
        var cut = range.upperBound
        var i = range.lowerBound
        while i < range.upperBound - 2 {
            if bytes[i] == UInt8(ascii: " "), bytes[i + 1] == UInt8(ascii: "S"),
                bytes[i + 2] >= 48, bytes[i + 2] <= 57
            {
                cut = i
            }
            i += 1
        }
        var scalars = [UInt8]()
        scalars.reserveCapacity(cut - range.lowerBound)
        for k in range.lowerBound..<cut { scalars.append(bytes[k]) }
        return String(decoding: scalars, as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Anwenden

    /// Marks the series of a category for which there is no episode.
    ///
    /// **Two safeguards, both in the same direction** — when in doubt the
    /// title stays untouched:
    ///
    /// 1. A directory with fewer than ``minimumUsable`` titles is not used.
    /// 2. If **not a single** title of a category is found again,
    ///    nothing is marked. A category in which everything is empty exists
    ///    in theory; more likely is a name spelling that does not
    ///    match — and then the whole category would be gray.
    ///
    /// The opposite error is harmless: an empty title that stays colorful
    /// behaves as it did before this change.
    public func marking(_ items: [MediaItem]) -> [MediaItem] {
        guard isUsable else { return items }

        let series = items.filter { $0.kind == .series }
        guard !series.isEmpty else { return items }

        let known = series.filter { hasEpisodes($0.title) }.count
        guard known > 0 else {
            Diagnostics.verbose(
                "Episode index: not a single one of \(series.count) titles found again "
                    + "— nothing marked"
            )
            return items
        }

        return items.map { item in
            guard item.kind == .series else { return item }
            var marked = item
            marked.hasNoEpisodes = !hasEpisodes(item.title)
            return marked
        }
    }
}
