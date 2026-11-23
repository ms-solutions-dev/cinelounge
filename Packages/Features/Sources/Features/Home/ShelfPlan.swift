import Core
import Flows
import Foundation

/// Which shelves the Home screen can show **at all** — the one truth about that.
///
/// **This file exists because of a finding of 2026-09-12 in the evening.** The Home screen builds
/// its rows in ``HomeModel/buildShelves(libraries:resumable:)``, and the shelf management
/// under "Appearance" built its list **separately from it** — from `source.libraries()` without
/// music and Live. Both sides were right on their own and drifted apart:
///
/// * **"From the portals" and "Collections" were missing from the list entirely.** Two rows that
///   stand on the Home screen and could be neither moved nor switched off — and that
///   over an identifier whose own comment explains it is *fixed* precisely so that
///   ``ShelfPreferences`` can remember order and visibility.
/// * **Instead, all portal levels stood in it individually** — a dozen Serieshub entry points
///   —, and a checkmark there did **nothing**: The Home screen merges them into *one* shelf with
///   the identifier ``ShelfRule/portalShelfID``.
///
/// **That is how the phone does it, and this is copied from it:** There `ShelfPlan` is the one
/// source that the Home screen **and** the reorder screen read from
/// (`ShelfPlan.shelves(forItem: state)`). The requirement of 2026-09-12 was expressly that it be
/// exactly like on the phone so that there is a recognition feature — and the
/// reason is not just habit: Two lists for the same question drift apart again, and next time
/// nobody notices.
///
/// **This file does not say what is in the shelves.** It says which ones exist. The
/// content is fetched by ``HomeModel``; a plan that also loads would be the second place where fetches
/// originate.
nonisolated enum ShelfPlan {

    /// A shelf as it is up for selection.
    struct ShelfRow: Identifiable, Equatable, Sendable {

        let id: String
        /// Finished text and no key — the names of the libraries come from the
        /// server and have none.
        let name: String
        /// What kind of library the row comes from; `nil` for the fixed shelves.
        /// Needed for the default order (``HomeModel/defaultOrder(_:)``).
        let kind: Core.Library.Kind?

        /// **"Continue Watching" stays put.** The same decision as on the phone
        /// (there ``StartPreferences/immovable``): A switch that does not give way
        /// would be a button without effect.
        var immovable: Bool { id == ShelfPreferences.resumeID }
    }

    /// The shelves in the default sequence — **the board of both programs**
    /// (``Flows/ShelfSequence``): Continue Watching · Collections · Live · Recently Added ·
    /// Portals · Catalogs. Since decision 27 (C3) "Recently Added" stands here too before
    /// the portals, as on the phone — first one's own, then the foreign.
    ///
    /// - Parameters:
    ///   - bibliotheken: Everything the collective source reports — **unfiltered.** Which ones get a
    ///     shelf is decided by ``ShelfRule/forShelves(_:)`` and not by the caller;
    ///     exactly this double decision was the error.
    ///   - sammlungen: Whether the media server holds collections.
    ///   - senderliste: Whether a channel list is set up.
    ///   - portalordner: The chosen portal folders. **Empty means "one shelf across all"**
    ///     — the same either-or rule as in ``HomeModel``: Both side by side would be
    ///     the same content twice.
    static func shelves(
        libraries: [Core.Library],
        collections: Bool,
        channelList: Bool,
        portalFolders: [ShelfPreferences.PortalChoice] = [],
        perProvider: Int = 2,
        categories: [String] = []
    ) -> [ShelfRow] {
        var rows: [ShelfRow] = [
            ShelfRow(
                id: ShelfPreferences.resumeID,
                name: AppLanguageSetting.text("home.continueWatching"),
                kind: nil)
        ]

        if collections {
            rows.append(
                ShelfRow(
                    id: HomeModel.collectionsID,
                    name: AppLanguageSetting.text("home.collections"),
                    kind: nil))
        }

        // **The channel list stands here although its switch also hangs under "Live".**
        // Both write to the same store (``ShelfPreferences`` under ``LiveShelf``'s
        // identifier) — that is expressly built so that there are no two truths.
        // Leaving it out here would mean treating this one shelf as the only one that
        // is not ordered where all the others are ordered.
        if channelList {
            rows.append(
                ShelfRow(
                    id: LiveShelf.identifier,
                    name: AppLanguageSetting.text("home.liveNow"),
                    kind: nil))
        }

        // **"Recently Added" stands before the portals and the libraries** — the
        // sequence of the board (``ShelfSequence``). It appears only if at least
        // one library contributes: Without a media server and without a provider catalog there is
        // no "new since yesterday", only portal menus.
        if ShelfRule.forShelves(libraries, perProvider: perProvider, categories: categories).contains(
            where: {
                !RecentShelf.withoutContribution.contains($0.kind)
            })
        {
            rows.append(
                ShelfRow(
                    id: RecentShelf.identifier,
                    name: AppLanguageSetting.text("home.recentlyAdded"),
                    kind: nil))
        }

        // **Either one shelf across all portals or one per chosen folder.**
        // The same rule as in ``HomeModel/buildShelves(libraries:resumable:)``; whoever
        // offers both here promises a row that does not exist.
        if !portalFolders.isEmpty {
            // **The portal must be reported, not the level** — see
            // ``ShelfRule/portalReported(forItem:under:)``; a deeply chosen folder stands
            // in no list of entry points.
            rows +=
                portalFolders
                .prefix(ShelfPreferences.maximumPortalFolders)
                .filter { ShelfRule.portalReported(forItem: $0.identifier, under: libraries) }
                .map { ShelfRow(id: $0.identifier, name: $0.name, kind: .portalLevel) }
        } else if libraries.contains(where: { $0.kind == .portalLevel }) {
            // **One shelf for all portals, not one per entry point.** The reasoning
            // is at ``ShelfRule/portalShelf(from:)``: With two portals it would be two
            // dozen rows from one origin.
            rows.append(
                ShelfRow(
                    id: ShelfRule.portalShelfID,
                    name: AppLanguageSetting.text("common.fromPortals"),
                    kind: .portalLevel))
        }

        rows += ShelfRule.forShelves(libraries, perProvider: perProvider, categories: categories).map {
            ShelfRow(id: $0.id, name: $0.name, kind: $0.kind)
        }

        return ShelfSequence.arrange(rows, identifier: \.id, kind: \.kind)
    }
}
