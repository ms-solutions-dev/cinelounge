@preconcurrency import AVFoundation
import Foundation

/// Which audio track a YouTube trailer plays: **never a dubbed version** (2026-11-08).
///
/// Requirement: no AI translation … if there is an original German trailer, then
/// German, otherwise always the original language. Verified on the Mac: for many
/// videos YouTube delivers all dubbed versions in the same HLS manifest (23 next to
/// the original in the sample video), each with `AUTOSELECT=YES`; without
/// intervention AVPlayer picked "Deutsch - dubbed" according to the system language.
/// Which track is which is stated in the track title (`NAME` in the manifest, the
/// metadata title in AVFoundation): `American English - original`,
/// `Deutsch - dubbed` — AI versions also run under `dubbed`.
///
/// **The rule applies only where this marker is present.** Tracks from Jellyfin, IPTV
/// or portals never carry it and stay untouched; so does a trailer with only one
/// track.
public enum OriginalAudio {

    /// An audio track as the choice sees it — checkable without AVFoundation.
    public struct Track: Equatable, Sendable {
        public let title: String
        public let language: String?

        public init(title: String, language: String?) {
            self.title = title
            self.language = language
        }

        var isOriginal: Bool { title.lowercased().hasSuffix("- original") }
        var isDubbed: Bool { title.lowercased().contains("dubbed") }
    }

    /// The index of the track that should play — `nil` when there is nothing to decide.
    ///
    /// Order: the German original before any other original; if there is none marked as
    /// original, the first track without a dub marker. Dubbed versions never.
    public static func choice(_ tracks: [Track]) -> Int? {
        guard tracks.contains(where: { $0.isOriginal || $0.isDubbed }) else { return nil }
        let originals = tracks.indices.filter { tracks[$0].isOriginal }
        if let german = originals.first(where: { isGerman(tracks[$0].language) }) { return german }
        if let first = originals.first { return first }
        return tracks.indices.first { !tracks[$0].isDubbed }
    }

    static func isGerman(_ language: String?) -> Bool {
        guard let s = language?.lowercased() else { return false }
        return s == "de" || s.hasPrefix("de-") || s == "deu" || s == "ger"
    }

    /// Applies the rule to a freshly created item — **before playback**, so that not a
    /// second of the dubbed version is heard.
    @MainActor
    public static func select(forItem item: AVPlayerItem) async {
        guard let group = try? await item.asset.loadMediaSelectionGroup(for: .audible) else {
            return
        }
        var tracks: [Track] = []
        for option in group.options {
            let titleEntry = option.commonMetadata.first { $0.commonKey == .commonKeyTitle }
            let title = (try? await titleEntry?.load(.stringValue)) ?? nil
            tracks.append(Track(title: title ?? option.displayName, language: option.extendedLanguageTag))
        }
        guard let index = choice(tracks) else { return }
        item.select(group.options[index], in: group)
    }
}
