import Core
import Foundation

/// **The channel list in sections — the same order on both devices** (decision
/// 27, B9, 2026-09-26).
///
/// **Four intentions, four sections, and their order is the frequency:** "my
/// channel" (last watched), "the one I bookmarked" (favourites), "what's on now"
/// (with programme) and last the rest without programme — question 10 of the phone, decided
/// on 09-06. Until 2026-09-26 this existed only in the phone's model; the TV showed
/// groups and channels and jumped to the last channel. Now both compute here.
///
/// **The two upper sections appear only above the unfiltered list** (`shelves`):
/// Whoever has chosen a group or is searching has asked a question; two sections that do not
/// answer it would then stand between them and the answer.
///
/// **Generic over the entry**, because the phone shows folded bundles and the
/// TV individual channels — the rule is the same, the row is not.
public nonisolated enum LiveOutline {

    public enum Kind: String, Sendable, CaseIterable {
        case recent = "zuletzt", favorites = "favoriten", withGuide = "mitProgramm", withoutGuide =
            "ohneProgramm"

        /// The heading — **`nil` for the main part.** "Channels" above the channel list would be
        /// a header that says what is there anyway.
        public var titleKey: String? {
            switch self {
            case .recent: "live.recent"
            case .favorites: "tab.favorites"
            case .withGuide: nil
            case .withoutGuide: "live.noGuideSection %lld"
            }
        }

        /// Whether the heading inserts the count.
        public var showsCount: Bool { self == .withoutGuide }

        /// Whether the section is a shortcut above the list and not the list itself —
        /// its entries appear a second time further down.
        public var isShelf: Bool { self == .recent || self == .favorites }
    }

    /// What is known about the programme of an entry.
    public enum Guide: Sendable, Equatable {
        /// Not asked yet — **counts toward the front section.** Whoever has not yet asked
        /// knows nothing, and a row that jumps from bottom to top after the late delivery
        /// is worse than one that stays put.
        case pending
        case none
        case available
    }

    public struct Segment<ContentEntryRecord: Sendable>: Sendable, Identifiable {
        public let kind: Kind
        public let entries: [ContentEntryRecord]
        public var id: String { kind.rawValue }

        public init(kind: Kind, entries: [ContentEntryRecord]) {
            self.kind = kind
            self.entries = entries
        }
    }

    /// Divides a list — **empty sections are dropped**: A header above nothing says
    /// nothing.
    ///
    /// - Parameters:
    ///   - eintraege: the list in the order in which it should appear.
    ///   - regale: whether "Recently watched" and "Favourites" appear above it.
    ///   - zuletzt: the names from ``ChannelHistory``, last watched first.
    ///   - name: the name under which the history knows an entry.
    public static func outline<ContentEntryRecord: Sendable>(
        _ entries: [ContentEntryRecord],
        shelves: Bool,
        recent: [String],
        name: (ContentEntryRecord) -> String,
        istFavorit: (ContentEntryRecord) -> Bool,
        program: (ContentEntryRecord) -> Guide
    ) -> [Segment<ContentEntryRecord>] {
        var segments: [Segment<ContentEntryRecord>] = []
        if shelves {
            let perName = Dictionary(
                entries.map { (name($0), $0) }, uniquingKeysWith: { first, _ in first })
            segments.append(Segment(kind: .recent, entries: recent.compactMap { perName[$0] }))
            segments.append(Segment(kind: .favorites, entries: entries.filter(istFavorit)))
        }
        segments.append(
            Segment(kind: .withGuide, entries: entries.filter { program($0) != .none }))
        segments.append(
            Segment(kind: .withoutGuide, entries: entries.filter { program($0) == .none }))
        return segments.filter { !$0.entries.isEmpty }
    }

    /// The list without its shortcuts — **what the player gets for switching onward.**
    public static func mainList<ContentEntryRecord>(
        _ segments: [Segment<ContentEntryRecord>]
    ) -> [ContentEntryRecord] {
        segments.filter { !$0.kind.isShelf }.flatMap(\.entries)
    }
}
