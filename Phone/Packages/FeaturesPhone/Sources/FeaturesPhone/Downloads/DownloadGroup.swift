import Downloads
import Foundation

/// A poster on the downloads screen — **a series or a single item, never an episode.**
///
/// **Requirement of 2026-09-09:** even when only 1 episode is downloaded, navigation in
/// Downloads is poster → detail view with the downloaded episodes, roughly like Jellyfin
/// content. Until then the screen was a flat list
/// of text rows: "1 - Pilot" above "Skiplu", five times one below the other, without a single
/// image. Five rows for one series are the same information five times — and the one that is
/// missing is which series it actually is.
///
/// **Grouping is done via ``Downloads/DownloadDescription/series`` and nothing else.** The series
/// title will not do: two series are called "Chaos"; and the same title is spelled differently
/// on a portal than on the media server. The identifier is the source's statement, the title
/// the translator's.
///
/// **Where no series is given, the item stands on its own.** That is not the error case but the
/// normal case for a film — and the emergency case for an old download for which no description
/// was ever stored. Both look the same: a poster slot with title and second line. What is
/// missing is the image, and for that ``EmptyTile`` draws the title into the surface — a
/// second construction next to it would be a second screen inside the screen.
struct DownloadGroup: Identifiable, Equatable {

    /// **From prefix and identifier, so that two spaces do not get in each other's way.** A job
    /// identifier and a series identifier are both strings from the same source; without a prefix,
    /// a film whose identifier happens to be that of a series could fall into the same slot as that
    /// series. The price is one word, the return is a class of errors nobody would look for.
    let id: String

    let title: String
    let beside: String?

    /// The poster as a **file in the downloads folder** — `nil` as long as none was stored.
    ///
    /// **A file and not an address**, and that is the whole point of downloads: A remembered TMDb
    /// address is an empty frame offline, so worth nothing exactly where this screen is needed. The
    /// reasoning is at ``Downloads/DownloadDescription/poster``; here the file name is only appended
    /// to the folder.
    let poster: URL?

    /// The series this belongs to — `nil` for a film and for everything without a description.
    ///
    /// **It is also the target of the tap.** For a group the poster leads to the series, for a
    /// single item to the title itself — see ``DownloadsView/openSeries``.
    let series: String?

    /// What lies in this group, in the order of the download ledger.
    let items: [DownloadJob]

    /// Whether **everything** lying here has been watched already.
    ///
    /// **Everything and not one.** A check mark on a series of which one of five episodes has been
    /// watched would be the information that cleanup goes by — and it would be wrong.
    let seen: Bool

    /// How many episodes it contains — `nil` for everything that is not a series.
    ///
    /// **Counted via ``Downloads/Extent/episodeCount`` and not via the items.** A queued season is
    /// **one** download job with eight episodes; anyone who counted items would write "1 episode"
    /// on a poster with eight behind it.
    let episodes: Int?

    /// The job that represents the group — for the tap without a series identifier.
    var representative: DownloadJob { items[0] }

    var count: Int { items.count }
    var identifiers: [DownloadJob.Identifier] { items.map(\.id) }
    var bytes: Int64 { items.reduce(0) { $0 + $1.estimatedSize } }

    /// The number on the poster — **always with its unit**, as ``CounterBadge`` demands. A
    /// bare "5" on a poster is a question and not information.
    var counter: String? {
        guard let episodes, episodes > 0 else { return nil }
        return SettingsModel.text("common.episodeCount %lld", episodes)
    }

    /// What is on the tile.
    ///
    /// **``PosterTile`` and not a frame of its own** — it can already do everything needed here:
    /// the missing image (then ``EmptyTile`` draws the title), the number in the corner, the
    /// watched check mark, the caption under the image and the hit area that matches the frame and
    /// not what is drawn.
    ///
    /// **``TileContent/wide`` is explicitly `false` and not `nil`.** What lies here is a poster —
    /// the contract in ``Downloads/DownloadDescription`` stores poster and background separately. `nil`
    /// would mean "unchecked", and an unchecked layer could switch between two and three columns
    /// depending on the catalog; the same series would then stand large at one time and small at
    /// another.
    var tile: TileContent {
        TileContent(
            id: id, title: title, beside: beside, image: poster,
            seen: seen, counter: counter, series: series, wide: false)
    }

    /// What the screen reader says.
    ///
    /// **Because ``PosterTile`` does not speak the number from the corner:** It combines its
    /// children and then sets a label of its own from title and second line — the number drops out
    /// in the process. To the eye it is the difference between one episode and five; to the ear it
    /// would not exist without this line.
    var spokenText: String {
        [title, beside, counter].compactMap { $0 }.joined(separator: ", ")
    }

    // MARK: - Grouping

    /// Combines the download jobs into posters.
    ///
    /// **The order of the download ledger stays.** A group stands where its first episode stood;
    /// anyone who has just queued something finds it at the top and not in a newly sorted list.
    /// Sorting is explicitly not done here — downloads are not an alphabet but a chronicle.
    ///
    /// - Parameters:
    ///   - beschreibungen: what was stored for the downloads, per job identifier.
    ///     **Empty is a valid case** — then every item stands on its own, and the screen still
    ///     works.
    ///   - ordner: the downloads folder to which the poster file names are appended. `nil`
    ///     means: no image, so title in the surface.
    ///   - gesehen: what the local history lists as watched.
    static func groups(
        from items: [DownloadJob],
        descriptions: [DownloadJob.Identifier: DownloadDescription] = [:],
        folder: URL? = nil,
        seen: Set<DownloadJob.Identifier> = []
    ) -> [DownloadGroup] {
        var order: [String] = []
        var slots: [String: [DownloadJob]] = [:]

        for job in items {
            let key =
                descriptions[job.id]?.series.map { "series:" + $0 }
                ?? ("item:" + job.id.rawValue)
            if slots[key] == nil { order.append(key) }
            slots[key, default: []].append(job)
        }

        return order.compactMap { key in
            guard let bucket = slots[key], let first = bucket.first else { return nil }
            return group(
                key, bucket, first: first, descriptions: descriptions,
                folder: folder, seen: seen)
        }
    }

    /// **The first description that says something wins — not the first one at all.**
    ///
    /// Ten episodes carry the same series description ten times (that is how the contract has it),
    /// but not every one has to be complete: an episode queued via the bridge can arrive without a
    /// poster, the next one with. Anyone who stubbornly took the first would show an empty frame
    /// although the file lies right next to it.
    private static func group(
        _ key: String, _ bucket: [DownloadJob], first: DownloadJob,
        descriptions: [DownloadJob.Identifier: DownloadDescription],
        folder: URL?, seen: Set<DownloadJob.Identifier>
    ) -> DownloadGroup {
        let own = bucket.compactMap { descriptions[$0.id] }
        let series = own.first?.series
        let posterName = own.compactMap(\.poster).first
        let year = own.compactMap(\.year).first

        // **The title of a group is the series title, not the episode title.** If it is not in the
        // description, the second line of the download job carries it: for a queued episode the title
        // is the episode title and ``DownloadJob/beside`` is the series — see ``Downloads/Extent/searchText``.
        let title: String
        let beside: String?
        if series != nil {
            title = own.compactMap(\.seriesTitle).first ?? first.beside ?? first.title
            beside = year.map(String.init)
        } else {
            title = own.first?.title ?? first.title
            beside = own.first?.beside ?? year.map(String.init) ?? first.beside
        }

        let episodeCount = bucket.reduce(0) { $0 + $1.extent.episodeCount }

        return DownloadGroup(
            id: key,
            title: title,
            beside: beside,
            poster: folder.flatMap { root in
                posterName.map { root.appendingPathComponent($0) }
            },
            series: series,
            items: bucket,
            seen: bucket.allSatisfy { seen.contains($0.id) },
            episodes: series != nil && episodeCount > 0 ? episodeCount : nil)
    }
}
