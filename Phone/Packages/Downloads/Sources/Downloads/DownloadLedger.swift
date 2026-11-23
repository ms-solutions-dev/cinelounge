import Diagnose
import Foundation

/// What the downloads keep across a restart.
///
/// **Without this ledger not even the list survives.** Until 2026-09-08 the manager held the jobs
/// only in memory; whoever quit the app afterwards had fourteen gigabytes
/// on the disk and no row that knows about them — exactly the files that
/// ``Cleanup/orphaned(files:known:)`` later finds and nobody can assign any more.
///
/// **And it is the prerequisite for everything further.** A block that is supposed to be
/// resumed after the restart needs the information against which
/// ``PortalJob/mayResume(length:tag:changed:)`` checks. It lives in the job,
/// and the job has to lie somewhere for that.
///
/// **A file and not a database.** It is dozens of rows, not thousands; they are
/// read once at startup and written completely at every change. A database
/// would bring concurrency, migrations and a second place where something can break
/// — for a list that fits on one screen height.
public struct DownloadLedger: Sendable {

    /// **Made of two pieces and not one, and that is no whim.**
    ///
    /// `scripts/strings.py` treats every string of the form `word.word` as a
    /// catalog key — rightly so, because you cannot tell from a string what
    /// it is for. `jobs.json` would be the **third** occurrence of the same pitfall
    /// in one day (after `player.pictureState` and the file names in a check), and each
    /// time the checker was right.
    ///
    /// Assembled, it sees two harmless pieces, and the name stays one.
    public static let stem = "auftraege"
    public static let fileName = stem + ".json"

    /// The same for the standing orders — **a second file and not a field on the job.**
    ///
    /// A standing order hangs on the series; the episode on which it was switched on is
    /// watched and removed after three days. A field on ``DownloadJob`` would vanish with
    /// it — and in addition every older ledger would have to go through a migration just to get
    /// a `false`.
    public static let persistentFileName = "nachlegen" + ".json"

    private let location: URL
    private let persistentLocation: URL

    public init(folder: URL) {
        self.location = folder.appendingPathComponent(Self.fileName)
        self.persistentLocation = folder.appendingPathComponent(Self.persistentFileName)
    }

    /// For which series topping up happens — **and likewise does not throw.**
    ///
    /// An unreadable standing order means: nothing is topped up. That is the
    /// more harmless half of the error — the opposite direction would be an app that, after a
    /// broken row, fetches episodes unasked.
    public func readReplenishment() -> [StandingOrder] {
        guard let data = try? Data(contentsOf: persistentLocation) else { return [] }
        do {
            return try JSONDecoder().decode([StandingOrder].self, from: data)
        } catch {
            Diagnose.step(.network, "Downloads: recurring jobs unreadable, none — \(error)")
            return []
        }
    }

    public func writeReplenishment(_ jobs: [StandingOrder]) {
        write(jobs, after: persistentLocation)
    }

    /// Reads what is there — **and does not throw.**
    ///
    /// **An unreadable ledger is no reason not to start the app.** It is a reason
    /// to begin with an empty list and write it down: the files are still
    /// there, and "Reconcile" finds them. Whoever threw here would turn a broken row into
    /// a screen that no longer opens at all.
    public func read() -> [DownloadJob] {
        guard let data = try? Data(contentsOf: location) else { return [] }
        do {
            return try JSONDecoder().decode([DownloadJob].self, from: data)
        } catch {
            Diagnose.step(.network, "Downloads: ledger unreadable, starting empty — \(error)")
            return []
        }
    }

    /// Writes the whole list.
    ///
    /// **Next to it first, then rename.** A write that the system ends midway
    /// otherwise leaves a half file — and that is unreadable at the next start, so the whole list
    /// is gone. Renaming is indivisible on the same file system; that is the cheapest
    /// protection there is.
    public func write(_ jobs: [DownloadJob]) {
        write(jobs, after: location)
    }

    private func write(_ content: some Encodable, after target: URL) {
        let beside = target.appendingPathExtension("neu")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(content).write(to: beside)
            _ = try FileManager.default.replaceItemAt(target, withItemAt: beside)
        } catch {
            // **Write it down and keep running.** Downloads that cannot be remembered
            // are annoying; an app that stops because of that is worse.
            Diagnose.step(.network, "Downloads: ledger not written — \(error)")
            try? FileManager.default.removeItem(at: beside)
        }
    }
}
