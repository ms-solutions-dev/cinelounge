import Foundation

/// Text subtitles, collected while repackaging a Matroska file.
///
/// **The finding** (F-035, 2026-10-03, "The Fikranou droblegleim Neidukli Hapril"): The chosen
/// track was an embedded SRT of 854 bytes. So that Jellyfin can deliver it, it reads
/// the **entire 11 GB file** from disk — 2¼ minutes of "Preparing subtitles", and
/// during that time the server read the whole disk once more next to the film.
/// 1,111 titles in the library carry embedded text subtitles, each pays that once.
///
/// Yet the blocks pass through the app anyway: The ``MatroskaRemuxer`` reads every
/// cluster, subtitles included, and used to throw them away. Now SRT and ASS land
/// here, piece by piece, just as playback reads ahead. What has not been repackaged
/// yet is missing — but the repackager always reads ahead of playback, so a line is
/// here before it is due.
///
/// Picture tracks (PGS, VobSub) stay with the server: They need their own paths.
public final class SubtitleCollector: @unchecked Sendable {

    private let lock = NSLock()
    /// Per track number the lines, keyed by block time — pieces overlap in the
    /// trailing run, and the same block then arrives twice.
    private var rows: [Int: [Int64: SubtitleCue]] = [:]
    private var progressStates: [Int: Int] = [:]

    public init() {}

    /// Whether a track can be collected here — text, not picture.
    public static func collectible(_ track: Matroska.Track) -> Bool {
        track.subtitleFormat == .subrip || track.subtitleFormat == .ass
    }

    /// Takes in a subtitle block.
    ///
    /// - Parameter skala: ``Matroska/Header/timestampScale`` — nanoseconds per time unit.
    func take(_ block: MatroskaReader.Block, track: Matroska.Track, scale: UInt64) {
        guard Self.collectible(track), let rawData = block.frames.first,
            let raw = String(data: rawData, encoding: .utf8)
        else { return }
        let start = Double(block.timestamp) * Double(scale) / 1_000_000_000
        // Without a duration, Matroska shows the line until the next one — five seconds
        // is the honest approximation that lets no line stand forever.
        let duration = block.duration.map { Double($0) * Double(scale) / 1_000_000_000 } ?? 5
        guard
            let row = track.subtitleFormat == .ass
                ? Self.assLine(raw, header: track.codecPrivate, start: start, end: start + duration)
                : Self.srtLine(raw, start: start, end: start + duration)
        else { return }

        lock.lock()
        defer { lock.unlock() }
        if rows[track.number, default: [:]].updateValue(row, forKey: block.timestamp) == nil {
            progressStates[track.number, default: 0] += 1
        }
    }

    /// All lines of a track collected so far, ordered by start.
    public func cues(track: Int) -> [SubtitleCue] {
        lock.lock()
        defer { lock.unlock() }
        return (rows[track] ?? [:]).sorted { $0.key < $1.key }.map(\.value)
    }

    /// How many lines a track has — if it changes, fetching again is worthwhile.
    public func state(track: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return progressStates[track] ?? 0
    }

    // MARK: - Lesen

    static func srtLine(_ raw: String, start: TimeInterval, end: TimeInterval) -> SubtitleCue? {
        let text = raw.components(separatedBy: .newlines)
            .map { WebVTTSubtitles.clean($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        guard !text.isEmpty else { return nil }
        return SubtitleCue(start: start, end: end, text: text)
    }

    /// An ASS block in Matroska is a dialogue line **without times**:
    /// `ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text`. The styles
    /// are in the track header. A small ASS document with one line is built from it so
    /// that ``ASSSubtitles/parse(_:)`` reads the position from the style and `\on`
    /// as with a file.
    static func assLine(
        _ raw: String, header: Data?, start: TimeInterval, end: TimeInterval
    ) -> SubtitleCue? {
        let fields = raw.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
        guard fields.count == 9 else { return nil }
        var document = header.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        if !document.lowercased().contains("[events]") {
            document +=
                "\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, "
                + "MarginV, Effect, Text"
        }
        let row = ([fields[1], "0:00:00.00", "0:00:01.00"] + fields[2...]).joined(separator: ",")
        document += "\nDialogue: " + row + "\n"
        guard var cue = ASSSubtitles.parse(document).first else { return nil }
        cue.start = start
        cue.end = end
        return cue
    }
}

extension SubtitleCollector {

    /// Which Matroska track lies behind an embedded Jellyfin subtitle track.
    ///
    /// **Strict, because a wrong pick is worse than waiting:** Wrong subtitles look
    /// like right ones. Jellyfin counts the tracks by ffprobe, Matroska by its own
    /// numbers — so the **order** of the embedded tracks is compared, and only if both
    /// sides know the same number. Format and language have to match as well. When in
    /// doubt `nil`, and the player fetches the track from the server as before.
    public static func matroskaTrack(
        forItem chosen: MediaTrack, all: [MediaTrack], file: [Matroska.Track]
    ) -> Matroska.Track? {
        guard chosen.kind == .subtitle, !chosen.isExternal else { return nil }
        let embedded = all.filter { $0.kind == .subtitle && !$0.isExternal }
            .sorted { (Int($0.id) ?? 0) < (Int($1.id) ?? 0) }
        guard embedded.count == file.count,
            let location = embedded.firstIndex(where: { $0.id == chosen.id })
        else { return nil }
        let track = file[location]
        guard collectible(track), formatFits(chosen.subtitleFormat, track.subtitleFormat) else { return nil }
        if let language = chosen.language, !track.language.isEmpty, track.language != "und",
            languageCode(language) != languageCode(track.language)
        {
            return nil
        }
        return track
    }

    private static func formatFits(
        _ jellyfin: MediaSource.SubtitleFormat?, _ file: Matroska.SubtitleFormat?
    ) -> Bool {
        switch (jellyfin, file) {
        case (.srt?, .subrip?), (.subrip?, .subrip?): true
        case (.ass?, .ass?), (.ssa?, .ass?): true
        default: false
        }
    }

    /// ISO 639-2 has two codes for some languages — Matroska mostly writes the
    /// bibliographic one (`ger`), Jellyfin the terminological one (`deu`).
    static func languageCode(_ raw: String) -> String {
        let code = raw.lowercased()
        let pairs = [
            "ger": "deu", "fre": "fra", "dut": "nld", "chi": "zho", "cze": "ces", "gre": "ell",
            "per": "fas", "rum": "ron", "slo": "slk", "alb": "sqi", "arm": "hye", "baq": "eus",
            "bur": "mya", "geo": "kat", "ice": "isl", "mac": "mkd", "mao": "mri", "may": "msa",
            "tib": "bod", "wel": "cym",
        ]
        return pairs[code] ?? code
    }
}
