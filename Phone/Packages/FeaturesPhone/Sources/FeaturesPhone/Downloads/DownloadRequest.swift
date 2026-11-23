import Downloads
import Foundation

/// What the download button reports when it is pressed.
///
/// **The scope comes from the trigger, and that is stated in this type.** Until 2026-09-08 the
/// button only passed an identifier upward; the switch built a film from it — even when it
/// belonged to a season. The design has said otherwise from day one: *"From the menu on an
/// episode, 'Only this episode' comes first; from the menu on the title, the whole season."*
/// Anyone who wants to take two episodes along for the train ride should not have to load
/// 4.9 GB.
///
/// **And the title belongs with it.** This is the only place where it is known: The switch
/// knows an identifier, the detail page knows the name. A downloads list whose rows are called
/// `jf-8dec87ad` is a list nobody can read.
public struct DownloadRequest: Sendable, Hashable {

    public let identifier: String
    public let title: String
    public var beside: String?
    public let extent: Extent
    public let source: SourceKind

    /// How long **one** episode or the film plays — **`nil` where the source says nothing.**
    ///
    /// **New on 2026-09-09.** Without it ``DownloadChoice`` calculated with a hard-coded 48 minutes and
    /// wrote 720 MB into the sheet for every title (product owner's finding). It lives here because
    /// this is the only place on the path to the download job where the title is still known —
    /// just like ``title`` and for the same reason.
    ///
    /// **Jellyfin has it** (`MediaItem.runtime` in `Core`, ROADMAP `@89b0f97`), **Serieshub does
    /// not** (`dauer_minuten: null`, measured at the bridge). The one who fills the value is the
    /// detail page; as long as it does not, the sheet names no size — and that is the right
    /// information and not the error case.
    public var runtime: TimeInterval?

    /// Which series this belongs to — **`nil` for a film.**
    ///
    /// **The series identifier and not the episode's**, because the standing order hangs on it: The
    /// episode on which "Queue next" was switched on is watched and removed in three days. It comes
    /// from the detail page because only that knows it.
    public var series: String?

    public init(
        identifier: String, title: String, beside: String? = nil, extent: Extent,
        source: SourceKind, runtime: TimeInterval? = nil, series: String? = nil
    ) {
        self.identifier = identifier
        self.title = title
        self.beside = beside
        self.extent = extent
        self.source = source
        self.runtime = runtime
        self.series = series
    }

    /// The job, as far as it is fixed without the sheet.
    ///
    /// **Without tier and without version**, and therefore it is not yet ``DownloadJob/complete``
    /// — that is decided by ``DownloadChoice``. Filling it here already would mean making the choice and
    /// then asking about it afterwards.
    public var job: DownloadJob {
        DownloadJob(
            id: .init(identifier), title: title, beside: beside, source: source, extent: extent,
            runtime: runtime)
    }
}

extension SourceKind {

    /// From the origin of a catalog — **`nil` where nothing can be downloaded.**
    ///
    /// A channel has no beginning and no end; what you downloaded from it would be a recording and
    /// not a copy. And downloads are not a source of themselves.
    public init?(_ origin: Catalog.Origin) {
        switch origin {
        case .jellyfin: self = .jellyfin
        case .provider: self = .provider
        case .portals: self = .portal
        case .channelList, .downloads: return nil
        }
    }
}
