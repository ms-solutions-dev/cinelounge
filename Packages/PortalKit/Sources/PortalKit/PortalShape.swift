import Core
import Foundation

/// How a portal level is drawn and when a portal search starts — **the two rules that TV and
/// phone each kept themselves** (AP58 R7, finding E4).
///
/// **The finding:** `PortalLevel.areFolders` on the TV checked the kind `.folder`,
/// `PortalLayer.areFolders` on the phone whether ``PortalSource/levelID(forItem:)`` names a level
/// — the same rule in two readings. The search constants (700 ms, from two characters) stood
/// on the TV twice, one of them unused, and the phone had none.
public enum PortalShape {

    /// Whether a level is drawn as **rows** instead of a grid.
    ///
    /// **The shape decides the level, not the tile** — and in this direction because the other one
    /// was wrong once already (viewer finding 2026-08-28: two folders turned 25 posters into a row
    /// list). A grid is shown as soon as there is something to show; rows remain only where the
    /// level consists **exclusively** of folders and section headings. An empty level is no folder
    /// list.
    ///
    /// - Parameter ordnerOderTrenner: whether an entry leads deeper or merely structures — for a
    ///   ``Core/MediaItem`` the answer is in ``isFolderOrSeparator(_:)``.
    public static func areFolders<ContentEntryRecord>(
        _ entries: [ContentEntryRecord], folderOrSeparator: (ContentEntryRecord) -> Bool
    ) -> Bool {
        !entries.isEmpty && entries.allSatisfy(folderOrSeparator)
    }

    /// The same rule for the entries as the bridge delivers them.
    public static func areFolders(_ items: [MediaItem]) -> Bool {
        areFolders(items, folderOrSeparator: isFolderOrSeparator)
    }

    /// Whether an entry leads deeper (``PortalSource/levelID(forItem:)``, the one place for "leads
    /// deeper") or is a section heading.
    public static func isFolderOrSeparator(_ item: MediaItem) -> Bool {
        PortalSource.levelID(forItem: item) != nil || item.kind == .separator
    }
}

/// When a portal search starts.
///
/// **A portal script asks a third-party site**, measured at one to two seconds per request. While
/// typing it therefore waits and asks only from two characters; a submitted term, by contrast,
/// is a decision and applies from one character.
public enum PortalSearch {

    /// How long to wait after the last keystroke — **longer than the 350 ms of the global
    /// search**, because there the own media server on the home network answers.
    public static let pause: Duration = .milliseconds(700)

    /// From how many characters to search while typing. A single letter hits almost everything and
    /// says nothing.
    public static let fromCharacter = 2

    /// The term that is searched for — or `nil` if (not yet) searching.
    /// - Parameter beimTippen: `true` for search during input (TV), `false` for a submitted term
    ///   (phone, "New Search").
    public static func term(_ input: String, whileTyping: Bool) -> String? {
        // **One threshold for both devices** (AP77, 2026-10-11): until then the phone searched from
        // one character, the TV from two — and with ten thousand series a letter is not a question
        // but a page that the server collects for five seconds.
        let word = input.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = whileTyping
        return word.count >= fromCharacter ? word : nil
    }
}
