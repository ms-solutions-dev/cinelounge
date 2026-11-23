import Diagnose
import Foundation

/// What the downloads know about their titles — **the second ledger next to
/// ``DownloadLedger``.**
///
/// **Why a second one and not a field on the download job** (finding of 2026-09-09): A
/// ``DownloadJob`` is the agreement about a transfer — path, scope, rule, size. It is
/// written at every state change, that is, every second as long as anything is running. The
/// description, by contrast, changes exactly once: when queued. Writing both into one file
/// would mean writing a few hundred bytes of blurb and cast at every progress step — and at
/// the first half-finished write both would be gone.
///
/// **The same build as ``DownloadLedger``, deliberately down to the lines.** JSON in the
/// downloads folder, read whole, written whole, first beside it and then renamed, and it
/// does not throw. A second design next to it would be a second place where the same
/// mistakes can be made again — and a reader would have to understand twice what is to be
/// understood once.
public struct DescriptionLedger: Sendable {

    /// **Built from two pieces, as with ``DownloadLedger/stem``.** `scripts/strings.py` treats
    /// every string of the form `word.word` as a catalog key; `descriptions.json` would be
    /// the next occurrence of the same pitfall.
    public static let stem = "beschreibungen"
    public static let fileName = stem + ".json"

    private let location: URL

    public init(folder: URL) {
        self.location = folder.appendingPathComponent(Self.fileName)
    }

    /// Reads what is there — **and does not throw.**
    ///
    /// **An unreadable ledger is the loss of the descriptions and not of the downloads.** The
    /// files stay, the list stays, and the detail page falls back to what it had before:
    /// nothing. Whoever threw here would turn a lost blurb into a screen that no longer opens.
    public func read() -> [DownloadDescription] {
        guard let data = try? Data(contentsOf: location) else { return [] }
        do {
            return try JSONDecoder().decode([DownloadDescription].self, from: data)
        } catch {
            Diagnose.step(.downloads, "Downloads: descriptions unreadable, starting empty — \(error)")
            return []
        }
    }

    public func description(zu identifier: String) -> DownloadDescription? {
        read().first { $0.id == identifier }
    }

    /// Writes the whole list — **first beside it, then rename.**
    ///
    /// The reasoning is at ``DownloadLedger/write(_:)`` and applies here unchanged: A write
    /// that the system ends in the middle otherwise leaves half a file, and that is unreadable
    /// at the next launch.
    public func write(_ descriptions: [DownloadDescription]) {
        let beside = location.appendingPathExtension("neu")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(descriptions).write(to: beside)
            _ = try FileManager.default.replaceItemAt(location, withItemAt: beside)
        } catch {
            // **Record and keep running** — the same choice as in the download ledger. A download
            // without a description is annoying; a download that does not start for that reason is
            // worse.
            Diagnose.step(.downloads, "Downloads: descriptions not written — \(error)")
            try? FileManager.default.removeItem(at: beside)
        }
    }

    /// Stores a description — **and replaces the one with the same ID.**
    ///
    /// **Replace and not append**, because the same episode can be queued a second time
    /// (removed, loaded again) and because ``DownloadDescription/storedAt`` would otherwise
    /// stand at the state of the first time. Two rows with the same ID would also be two
    /// answers to the same question, and which one applies would be decided by the order in the
    /// ledger.
    public func create(_ description: DownloadDescription) {
        var all = read()
        all.removeAll { $0.id == description.id }
        all.append(description)
        write(all)
    }

    /// Removes a description and says **which images nobody needs any more as a result.**
    ///
    /// - Returns: the file names that, after the removal, appear in no remaining description.
    ///   Whoever deletes them deletes nothing that is still shown.
    @discardableResult
    public func remove(_ identifier: String) -> [String] {
        let previous = read()
        guard previous.contains(where: { $0.id == identifier }) else { return [] }
        let after = previous.filter { $0.id != identifier }
        write(after)
        return Self.orphanedImages(from: identifier, previous: previous)
    }

    /// **The case that ``DownloadDescription`` names explicitly in its DocC.**
    ///
    /// Ten episodes of a series carry the same poster file name ten times — the same file, not
    /// ten times the space. Whoever deletes one of them and takes its images with it takes the
    /// poster away from the series, and in the downloads screen an empty frame then sits above
    /// nine episodes that still exist.
    ///
    /// **What is asked is the file name and not the series.** Going by series would be the
    /// narrower rule and at the same time the wrong one: Two series can share a cast image (the
    /// same actor, the same face) — the name is a hash of the image address and the same for
    /// the same address. What counts is whether anybody still names the name.
    ///
    /// **A pure calculation without a folder**, so that it can be tested without deleting
    /// anything.
    public static func orphanedImages(
        from identifier: String, previous: [DownloadDescription]
    ) -> [String] {
        guard let departing = previous.first(where: { $0.id == identifier }) else { return [] }
        let remaining = Set(previous.filter { $0.id != identifier }.flatMap(\.imageNames))
        return departing.imageNames.filter { !remaining.contains($0) }
    }

    /// What belongs to the downloads without being a movie — **for the reconciliation.**
    ///
    /// **The finding of 2026-09-09, found while building and not on screen:**
    /// `StorageView.reconcile()` lists the downloads folder and considers everything orphaned
    /// that is not `Store.fileName(forItem:)` of a known ID. Even before, `jobs.json` and
    /// `queueNew.json` counted as orphans; with the image files a few hundred would be added,
    /// and the reported number would be pure invention. Nothing is deleted there — the message
    /// is still a piece of information, and a wrong piece of information is worse than none.
    public func knownFiles() -> Set<String> {
        var names: Set<String> = [Self.fileName, DownloadLedger.fileName, DownloadLedger.persistentFileName]
        names.formUnion(read().flatMap(\.imageNames))
        return names
    }
}
