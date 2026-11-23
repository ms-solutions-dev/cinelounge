import Foundation

/// **Filter and search in the log — the same rule on both devices** (decision 27,
/// C17).
///
/// The phone could already search its log and highlight conspicuous entries; the
/// TV showed its trace unfiltered. Both now ask here.
public nonisolated enum LogSearch {

    /// Whether an entry matches the search word — **case-insensitive**;
    /// an empty word lets everything through.
    public static func matches(_ text: String, word: String) -> Bool {
        let needle = word.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return true }
        return text.localizedCaseInsensitiveContains(needle)
    }

    /// Whether a log line is conspicuous — a failure (`✗`) or a warning (` ! `).
    public static func isNotable(_ row: String) -> Bool {
        row.contains("✗") || row.contains(" ! ")
    }
}
