import Core
import Foundation

/// The most recently fetched levels of a CL-Server — and the most recently failed ones.
///
/// **Several instead of one, and the failures too** (AP74, 2026-10-11). Until then
/// ``PortalSource`` remembered exactly **one** level for twenty seconds: the view asks
/// the same level twice in quick succession (first "folder or title?", then the
/// titles), and that was enough for it. But whoever went back and forth between two
/// levels fetched anew every time — and whoever walked into a level whose fetch ran
/// into the server's 20 s deadline got the same error from the second reader after
/// another twenty seconds. Now ``slots`` holds levels ``lifetime`` long, and a
/// failure counts as an answer for ``failureTTL``: short enough that a
/// deliberate back-and-in again brings a fresh attempt.
struct LayerSlot {

    /// What is known about a level: its content or its failure.
    enum ContentEntryRecord {
        case level(PortalTier)
        case failure(any Error)
    }

    /// How long a fetched level is valid. Short enough that a deliberate
    /// back-and-in-again brings fresh data.
    static let lifetime: TimeInterval = 20
    /// How long a failure counts as an answer — only against the second reader of the same
    /// level, not against a new attempt by the viewer.
    static let failureTTL: TimeInterval = 5
    /// How many levels have room — a back and forth across a few folders, not a catalog.
    static let slots = 8

    private var entries: [(id: Library.ID, since: Date, entry: ContentEntryRecord)] = []

    /// The valid entry for a level, or `nil`.
    func entry(forItem id: Library.ID, now: Date = Date()) -> ContentEntryRecord? {
        guard let found = entries.last(where: { $0.id == id }) else { return nil }
        let alter = now.timeIntervalSince(found.since)
        switch found.entry {
        case .level: return alter < Self.lifetime ? found.entry : nil
        case .failure: return alter < Self.failureTTL ? found.entry : nil
        }
    }

    mutating func memorize(_ level: PortalTier, forItem id: Library.ID, now: Date = Date()) {
        create((id, now, .level(level)))
    }

    mutating func memorize(failure: any Error, forItem id: Library.ID, now: Date = Date()) {
        create((id, now, .failure(failure)))
    }

    /// Forgets everything — after a playback every level carries a new state.
    mutating func forget() { entries.removeAll() }

    /// Forgets one level — a portal's root as soon as "Recently used" has changed (a page
    /// opened or removed, 2026-10-12).
    mutating func forget(_ id: Library.ID) { entries.removeAll { $0.id == id } }

    var count: Int { entries.count }

    private mutating func create(_ fresh: (id: Library.ID, since: Date, entry: ContentEntryRecord)) {
        entries.removeAll { $0.id == fresh.id }
        entries.append(fresh)
        if entries.count > Self.slots { entries.removeFirst(entries.count - Self.slots) }
    }
}
