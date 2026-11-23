import Core
import Downloads
import Foundation
import Observation

/// What is currently chosen in the download sheet — **and what that costs.**
///
/// **The calculations are here and not in the view body** (AP7). There are three, and each
/// is needed in several places: how large the chosen scope becomes at the chosen level,
/// how long that takes, and what is on the loud button.
///
/// **The sizes are calculated and not typed.** The design shows fixed numbers — 4.9 GB
/// for eight episodes in 720p —, and they are right for exactly this season. Instead,
/// the calculation is playing time times data rate: that also holds for a film, half a
/// season and a title the design never saw.
///
/// ## Why 720 MB stood everywhere until 2026-09-09
///
/// **The finding came from a simulator test:** every portal title showed the same
/// download size — *"[download sheet] cannot be right either, it feels like all portal
/// content is always 720 MB … something does not fit here."*
/// It was right, and it was worse than a bad estimate: it was a
/// **constant**. ``init(job:runtimePerEpisode:)`` hard-coded 48 minutes because no
/// source ever supplied a running time; 48 min × 2 Mbit/s (``Downloads/SelectionRule/suggestion``
/// is `.low`) is exactly 720,000,000 bytes to the byte. Every title, every series, every portal —
/// the same number, and the season row was eight times that.
///
/// **Re-measured at the bridge on 2026-09-09** (Bloufeit S1F1, Serieshub, host HOSTA):
///
/// | Fetch | Answer |
/// |---|---|
/// | `/p/serieshub/list` | `dauer_minuten: null` — for **all ten** episodes |
/// | `/p/serieshub/sources` | two hosts, **no** size information |
/// | `/play?…&weiterleiten=false` | `kind: "file"`, `gueltig_bis` ≈ 300 s, 0.99 s |
/// | Range request `bytes=0-1` | `206`, `content-range: bytes 0-1/561149891` |
///
/// The truth is **561 MB**; the fixed number was 28 % above it.
///
/// ## What stands there instead — and what was rejected
///
/// **Chosen: calculate where there is a running time, and otherwise write nothing.**
/// ``Downloads/DownloadJob/runtime`` carries it; if it is `nil`, ``size(forItem:)-(Extent)``
/// and the footer caption return `nil`, and the sheet shows nothing at that spot. That
/// is this project's house rule and no invention of today: ``Downloads/TimeEstimate``
/// returns `nil` without a measurement instead of a default, the trip planning took in no title
/// without a running time, and the image fill lacks the format for the direct renderer — everywhere
/// the same decision: no number is better than an invented one.
///
/// **Rejected: fetching the real size before display.** Technically it works — `/play`
/// delivers an address, a range request `bytes=0-1` delivers `Content-Range` and in it
/// the length. But the price is not *one* fetch but **one per episode**: the sheet
/// shows three scopes, and "Whole season" is the sum over eight of them. Measured, `/play`
/// took 0.99 s, `/sources` 0.63 s — one season would be about ten seconds of waiting for
/// a number that stands beside a choice. In addition the address expires after 300 s:
/// whoever fetches it on opening fetches it a second time on adding, and with the
/// provider every fetch occupies the account's **one** connection. A measurement that makes the
/// process more expensive than the information is worth is the wrong measurement.
///
/// **Rejected: storing a bandwidth per portal.** That would be the same constant with
/// more digits — it would only look less conspicuous, because not *all* titles would
/// be the same size any more, but all titles *of one portal*.
///
/// **And the sum remains an estimate, even if it consists of eight parts.** That is why
/// the single choice, the season sum and the loud button carry the same "about" — see
/// ``sizeText(forItem:)-(Extent)`` and ``footerCaption``.
@Observable
@MainActor
final class DownloadChoice {

    let job: DownloadJob

    var extent: Extent
    var tier: StreamQuality
    var version: String
    var host1: String

    var wifiOnly = true
    /// **Off by default.** Adding more is useful and costs bandwidth that nobody
    /// ordered; it is offered after the first finished download.
    var queueNew = false

    /// How long **one** episode plays — `nil` as long as nobody has said.
    ///
    /// **Until 2026-09-09 `48 * 60` stood here as the default**, and because not a single
    /// caller ever overrode it, it was the only running time the app knew. It
    /// is the cause of the 720 MB — see the head of this type.
    private let runtimePerEpisode: TimeInterval?

    /// - Parameter laufzeitJeFolge: Only for checks. In operation the running time comes with the job via
    ///   ``Downloads/DownloadJob/runtime``, because only the source knows it.
    init(job: DownloadJob, runtimePerEpisode: TimeInterval? = nil) {
        self.job = job
        self.extent = job.extent
        self.tier = job.tier ?? SelectionRule.suggestion
        self.version = job.version ?? ""
        self.host1 = job.host ?? ""
        self.runtimePerEpisode = runtimePerEpisode ?? job.runtime
    }

    // MARK: - Umfang

    /// **What is offered for choice depends on the trigger.** From the menu on an episode there
    /// are the episode and the season; for a film there is nothing to choose, and then
    /// the section is not there at all.
    ///
    /// **The 8 and the 14 are copied from the design and are only right there**
    /// (finding of 2026-09-09, noticed when re-measuring the sizes). "Bloufeit" has ten
    /// episodes in season 1 — counted at the bridge, not estimated —, and the sheet offers
    /// "Whole season · 8" anyway. The numbers do not come from here but from the
    /// detail page: it is the only place that knows `season.episodes.count` and the
    /// unwatched state, and it already passes them through correctly today at ``Extent/season(number:episodes:)``.
    /// The path is missing from the **Episodes** menu because
    /// ``Extent/episode(season:number:)`` carries no season length. To be fixed at
    /// ``DownloadRequest`` and the three `request(forItem:)` in `Detail/DetailView.swift`.
    ///
    /// **Visibly wrong as of today is only the number itself, no longer a size
    /// derived from it**: without a running time nothing stands next to the row.
    var extents: [Extent] {
        switch job.extent {
        case .film: []
        case .episode(let season, let number):
            [
                .episode(season: season, number: number),
                .season(number: season, episodes: 8),
                .unwatched(episodes: 14, seasons: 2),
            ]
        case .season(let number, let episodes):
            [.season(number: number, episodes: episodes), .unwatched(episodes: 14, seasons: 2)]
        case .unwatched: [job.extent]
        }
    }

    // MARK: - Sizes and times

    /// Playing time of the chosen scope — **`nil` if the running time is unknown.**
    ///
    /// **The season is the episode times its count**, and that is an extrapolation from
    /// **one** running time. It is still better than the fixed number from before: it is
    /// at least measured on this title and not on none. It stays recognisable as an
    /// estimate through the "about" that every number in this sheet carries.
    func duration(forItem extent: Extent) -> TimeInterval? {
        guard let runtimePerEpisode else { return nil }
        return extent.episodeCount == 0
            ? runtimePerEpisode : Double(extent.episodeCount) * runtimePerEpisode
    }

    /// How large this scope becomes at the **currently chosen** level.
    func size(forItem extent: Extent) -> Int64? {
        TimeEstimate.bytes(forRuntime: duration(forItem: extent), mbit: Self.mbit(tier))
    }

    /// How large the **chosen** scope becomes at this level.
    func size(forItem tier: StreamQuality) -> Int64? {
        TimeEstimate.bytes(forRuntime: duration(forItem: extent), mbit: Self.mbit(tier))
    }

    /// Whether the sheet can name sizes at all.
    ///
    /// **With the portals that is the normal case and not the exception** (measured on
    /// 2026-09-09: `dauer_minuten: null` for every episode of "Bloufeit"). The sheet therefore says so
    /// in one sentence instead of simply leaving a column empty — a missing
    /// number without a reason reads as a loading error.
    var isSizeUnknown: Bool { runtimePerEpisode == nil }

    /// "about 561 MB" — **or nothing.**
    ///
    /// **The "about" belongs on every one of these numbers and not only on the odd ones.** It
    /// arises from running time times an assumed data rate; nothing about it is measured. Only
    /// ``Downloads/DownloadJob/sizeIsCertain`` reports a real number, and that happens after the
    /// first `Content-Length`.
    static func sizeText(_ bytes: Int64?) -> String? {
        guard let bytes, bytes > 0 else { return nil }
        return SettingsModel.text("stock.sizeAbout %@", DownloadsModel.members(bytes))
    }

    func sizeText(forItem extent: Extent) -> String? { Self.sizeText(size(forItem: extent)) }

    func sizeText(forItem tier: StreamQuality) -> String? {
        Self.sizeText(size(forItem: tier))
    }

    /// **The data rate of a level, and for "Original" an honest assumption.**
    ///
    /// `StreamQuality.unlimited` intentionally has no limit — the server sends what the
    /// file has. A size estimate still needs a number; what is taken is
    /// the next higher level times 2.3, which corresponds to the ratio in the design (18.4 GB
    /// "Original" against 9.2 GB "1080p transcoded"). **This is an estimate and is called
    /// one in the sheet** — "about".
    static func mbit(_ tier: StreamQuality) -> Double {
        guard let bitrate = tier.bitrate else { return 20 * 2.3 }
        return Double(bitrate) / 1_000_000
    }

    // MARK: - Portalfassungen

    /// What the bridge names for this title — **`nil` as long as nobody has asked.**
    ///
    /// **It is not split up here.** `PortalSourceChoice` does that since the portals package:
    /// measured on 2026-09-06 at the real bridge, `/sources` for Animehub returns twelve rows
    /// for one episode — four hosts times three language versions —, for the ARD ten rows
    /// that are not hosts at all but resolution levels. A second split here
    /// would be the place where player and downloads show different lists.
    var sourceChoice: PortalSourceChoice?

    /// **Blocked ones are not shown here at all** — unlike in the player's source
    /// sheet, which shows them with their reason.
    ///
    /// The difference is intentional and stands that way in the design: whoever wants to play should
    /// **see** why a source does not work (the server marks some as not usable and
    /// names the reason, and "does not work" would be no information). Whoever **downloads**, on the other hand, chooses from
    /// what can carry — a grey control in a row looks like an
    /// error, and here it would be one, because `/play` would give no address for it.
    private var usable: PortalSourceChoice? {
        sourceChoice.map { PortalSourceChoice($0.rows.filter { !$0.locked }) }
    }

    var variants: [String] { usable?.variants ?? [] }

    /// The hosts, or — with the ARD — the resolution levels.
    ///
    /// **There is never both at once**, and which two things are offered for choice is decided by
    /// the portal and not by the build.
    var provider: [String] { usable?.provider ?? [] }
    var slots: [String] { usable?.slots ?? [] }

    /// **If nothing is left, the bridge's sentence is shown** — verbatim and not as
    /// "does not work". An empty sheet without a reason would be the worst of the three
    /// possibilities.
    var isOnlyBlocked: Bool {
        guard let sourceChoice, !sourceChoice.rows.isEmpty else { return false }
        return usable?.rows.isEmpty ?? true
    }

    /// **Without a size per host, and that is honest.** How large a file is is only told by
    /// its `Content-Length` — i.e. after the first block. A number per row would here be an
    /// estimate that looks like information; the estimate appears once at the foot, where it
    /// is recognisable as one.
    ///
    /// **And without "resumable" as long as nobody has asked.** That is decided by a
    /// range fetch before the first byte (``Resumability``); making it for every row in
    /// advance would mean four fetches for one display. If the chosen
    /// host does not carry, the job takes the next — that is in the footnote and
    /// happens without asking.
    ///
    /// **Since 2026-09-09 the last sentence is also true.** Until then it was a promise without
    /// a build: ``BackgroundSession`` threw ``LoadError/notResumable(_:)``, and **no
    /// caller in the whole project caught it** — the screen showed a warning triangle where a
    /// second attempt belonged. It is built now in ``AddressProvider/fallBack()``, and
    /// blocked rows are skipped there, just as here.
    var blockedReasons: [String] {
        (sourceChoice?.rows ?? []).filter(\.locked).compactMap(\.reason)
    }

    // MARK: - Ergebnis

    /// The row the choice in the sheet points to — **and not its name.**
    ///
    /// **The finding of 2026-09-09, measured at the bridge.** The job remembered what is on
    /// the screen: `host: "HOSTA"`. But `/play` wants the row's **ID**
    /// (`f=getHostUrl&entryUrl=…`), and to the name the bridge answered with
    ///
    ///     GET /play?portal=serieshub&quelle=HOSTA&weiterleiten=false  →  502 Bad Gateway
    ///
    /// **The name is not an ID, even if it reads like one.** "HOSTA" has two rows
    /// for "Bloufeit" — a German and an English one —, and which one is meant
    /// is only in the ID. That is exactly why ``PortalSourceChoice/match(provider:tier:version:)``
    /// takes three features and returns **one row.**
    ///
    /// **It is asked twice because the sheet writes two lists into one field.** With
    /// Animehub the hosts are in there (HOSTA, Hoste), with the ARD resolution levels
    /// (1080p, 720p); ``host1`` carries both. First host, then level — and if neither
    /// of the two is chosen, the first row of the version. That is the same rule by which
    /// the bridge takes the first usable host without any input.
    private var selectedRow: PortalHost? {
        guard let sourceChoice else { return nil }
        let choice = host1.isEmpty ? nil : host1
        let which = version.isEmpty ? nil : version
        return sourceChoice.match(provider: choice, version: which)
            ?? sourceChoice.match(tier: choice, version: which)
            ?? sourceChoice.match(version: which)
    }

    var finalizedJob: DownloadJob {
        var fresh = job
        fresh.tier = job.source == .jellyfin ? tier : nil
        fresh.host = job.source == .portal ? selectedRow?.id : nil
        fresh.version = job.source == .portal ? version : nil
        fresh.rule = NetworkRule(wifiOnly: wifiOnly)
        // **Zero means unknown** — see ``Downloads/DownloadJob/estimatedSize``. It
        // adds up harmlessly in the storage budget and claims nothing.
        fresh.estimatedSize = size(forItem: extent) ?? 0
        fresh.runtime = runtimePerEpisode
        return fresh
    }

    /// "Download about 4.4 GB" — **the number that is being decided against.**
    ///
    /// **And without a number just "Download"** (2026-09-09). Until then the button carried
    /// the bare amount and thereby the 720 MB as the loudest line of the sheet. A caption
    /// that carries an invented number is worse than one that carries none: it is the
    /// place where someone anchors their decision.
    var footerCaption: String {
        guard let bytes = size(forItem: extent), bytes > 0 else {
            return CaptionLabel.key("stock.putInStock").readable
        }
        return SettingsModel.text("stock.putAbout %@", DownloadsModel.members(bytes))
    }

    // MARK: - Namen

    static func name(forItem extent: Extent) -> String {
        switch extent {
        case .film: CaptionLabel.key("stock.scope.movie").readable
        case .episode(_, let number):
            CaptionLabel.key("detail.markEarlierOnly").readable + " \(number)"
        case .season(let number, _):
            CaptionLabel.key("stock.scope.season").readable + " \(number)"
        case .unwatched: CaptionLabel.key("stock.scope.unwatched").readable
        }
    }

    static func subRow(forItem extent: Extent) -> String? {
        switch extent {
        case .film, .episode: nil
        case .season(_, let episodes), .unwatched(let episodes, _):
            "\(episodes)"
        }
    }

    static func name(forItem tier: StreamQuality) -> String {
        switch tier {
        case .unlimited: CaptionLabel.key("quality.original").readable
        case .veryHigh: "4K"
        case .high: "1080p"
        case .medium: "1080p"
        case .low: "720p"
        case .minimal: "540p"
        }
    }

    static func subRow(forItem tier: StreamQuality) -> String? {
        tier == SelectionRule.suggestion
            ? CaptionLabel.key("stock.suggested").readable : nil
    }
}
