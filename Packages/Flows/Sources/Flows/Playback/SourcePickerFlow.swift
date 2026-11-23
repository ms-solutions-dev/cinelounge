import Diagnose
import Foundation
import Observation
import PortalKit

/// The source choice for a portal title in the player — host × language version, and "another
/// source" when the running one does not hold (AP58 G1, decision 27, A9).
///
/// **Why it exists.** The phone had had the choice in the player since 2026-09-06, the
/// TV only the permanent language of the series on the detail page; whoever stood there before a
/// dead mirror had as a way out "Try again" — the same dead source once
/// more. The decomposition (``PortalKit/PortalSourceChoice``) lives in PortalKit, the flow
/// here: when to fetch, what is running, and when a choice is worthwhile.
@Observable
public final class SourcePickerFlow {

    /// What this title offers in hosts, levels and versions.
    public private(set) var choice = PortalSourceChoice([])

    /// Which row is running right now — `nil` as long as nobody knows.
    public private(set) var running: String?

    /// Which title the choice applies to.
    ///
    /// **Per title and not per player.** On the phone it hung on the player until AP58 G1: after
    /// the next episode the sheet still showed the host list of the previous one.
    @ObservationIgnored private var forItem: String?

    public init() {}

    /// Whether there is anything to choose — otherwise the button is omitted, instead of opening a sheet with one
    /// row.
    public var isWorthwhile: Bool { choice.isWorthwhile }

    /// Fetches what is up for choice — **once per title and only when someone asks.**
    ///
    /// Every request goes to a third-party site, and which hosts an episode carries
    /// does not change while one is watching it. **A failure is a hint and
    /// not a malfunction:** the picture plays; what is missing is a choice that did not exist
    /// before either.
    public func load(forItem identifier: String, fetch: () async throws -> [PortalHost]) async {
        guard forItem != identifier || choice.rows.isEmpty else { return }
        do {
            let rows = try await fetch()
            forItem = identifier
            choice = PortalSourceChoice(rows)
            Diagnose.step(.playback, "Source picker: \(rows.count) rows")
        } catch {
            Diagnose.hint(.playback, "Source picker not fetched", error)
        }
    }

    /// Which row is running — after the start, when the source says so.
    ///
    /// **The server may take a different one** than the requested one if that does not hold;
    /// what is marked is the one that runs, not the one that was pressed.
    public func isRunning(_ row: String?) {
        if running != row { running = row }
    }

    /// Until when the running address is valid — named by the portal, otherwise `nil`.
    public private(set) var validUntil: Date?

    /// Like ``isRunning(_:)``, with the deadline of the freshly resolved address (AP77).
    public func isRunning(_ row: String?, validUntil: Date?) {
        isRunning(row)
        self.validUntil = validUntil
    }

    /// Whether the running address has expired — then "resolve again" is worthwhile, not "continue".
    public func expired(now: Date = Date()) -> Bool {
        guard let validUntil else { return false }
        return now >= validUntil
    }

    /// The rows that can be chosen, in the order of the bridge — **blocked ones
    /// drop out.** For the flat list of the track board on the TV; the phone asks the
    /// three fields individually (``PortalKit/PortalSourceChoice/suggestions(forItem:provider:tier:version:)``).
    public var selectable: [PortalHost] { choice.rows.filter { !$0.locked } }

    /// The label of a row in the flat list — "HOSTA · OmU".
    ///
    /// **The host alone is not enough:** with four hosts times three versions there would be
    /// "HOSTA" four times one below the other.
    public static func caption(_ row: PortalHost) -> String {
        guard let version = row.version, !version.isEmpty else { return row.header }
        return row.header + " · " + LanguageTag.short(version)
    }
}
