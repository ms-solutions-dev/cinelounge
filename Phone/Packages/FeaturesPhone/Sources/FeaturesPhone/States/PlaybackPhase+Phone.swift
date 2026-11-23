import Flows
import Foundation
import NetworkStatus

/// What of the shared ``PlaybackPhase`` concerns **only the phone** — where it appears, which ones still
/// have no producer, where its quiet path leads, and how the phone passes its situation to the
/// interpretation.
///
/// **Since AP58 R3 (2026-09-26) the state itself lives in `Flows`** — shape, key,
/// symbol and the failure interpretation, the same for TV and phone. What remains here is the
/// thin mapping onto the terms of this app.
extension PlaybackPhase {

    /// The states this phone can show — all except those of the TV.
    ///
    /// **The order is that of the design** (`entwuerfe/prototyp.html`), and the
    /// ``StateShowcase`` plays them through in that order: Loading · Empty · No network · Sign-in ·
    /// Abort · Provider · Portals · Cellular.
    static var onPhone: [PlaybackPhase] {
        allCases.filter { !tvOnly.contains($0) }
    }

    /// The states for which there is **no producer today** — each with its reason.
    ///
    /// **On 2026-09-06 there were eleven.** "Never set" is the quietest bug on this list: the
    /// state is there, the showcase demonstrates it — and on the device it never appears.
    ///
    /// * ``PlaybackPhase/loadingLong`` is the **second stage** of ``PlaybackPhase/loadingStart``;
    ///   ``LoadingState`` switches over by itself, only the showcase sets the case.
    /// * ``PlaybackPhase/abort`` belongs to the package **What iOS adds** — it arises at the
    ///   audio interruption.
    /// * ``PlaybackPhase/portalFetchAddress`` is a **progress indicator** and belongs to the package
    ///   **Portals**, together with the fallback itself.
    /// * ``PlaybackPhase/cellularPaused`` hangs on the "download on Wi-Fi only" switch; the downloads
    ///   pause per job and say so on the row — the better information.
    ///
    /// **`scripts/buttons.py` reads this list and compares it with the source** —
    /// that of the phone and that of the shared interpretation. States from
    /// ``PlaybackPhase/tvOnly`` are not needed here.
    static let withoutProducerYet: Set<PlaybackPhase> = [
        .loadingLong, .abort, .portalFetchAddress, .cellularPaused,
    ]

    /// **Whether the quiet path of this state leads to the downloads.**
    ///
    /// **Six states name it** ("Meanwhile to Downloads", "Open Downloads"), and
    /// the mapping lives here instead of at fourteen call sites. **A separate declaration
    /// and no comparison of the key:** a text may change, where a path leads
    /// is a decision.
    var sidePathLeadsToDownloads: Bool {
        switch self {
        case .loadingLong, .networkJellyfin, .networkPortals, .networkAirplaneMode, .loginExpired,
            .xtreamBusy:
            true
        default:
            false
        }
    }

    /// The view at whose head this state appears.
    ///
    /// A state does not belong to "the app" but to a place: "This library is empty"
    /// sits under the large title of the Library. **Airplane mode sits in the downloads**
    /// (since AP3): without a network there is no Home screen any more. **Handoff and remote**
    /// hang on the settings behind the profile picture of the Library. The TV's cases
    /// sit where their like would sit — they are never produced here.
    var host: ViewID {
        switch self {
        case .loadingStart, .loadingLong: .start
        case .networkAirplaneMode, .cellularPaused: .downloads
        case .emptyLibrary, .networkJellyfin, .jellyfinDisruption, .loginExpired,
            .abort, .notSetUpYet, .certificateSystemPlayer, .jellyfinWontPlay,
            .cameraDenied, .networkTV, .noConnection, .certificateUnconfirmed:
            .library
        case .emptySearch: .search
        case .emptyFavorites: .favorites
        case .emptyLiveHidden, .emptyLiveWithoutList, .xtreamBusy, .xtreamDeliversNothing,
            .xtreamRawStreamOnly, .xtreamAccessExpired, .networkXtream:
            .live
        case .networkPortals, .portalAddressExpired, .portalFetchAddress, .portalUnresolvable,
            .portalProfileRequired, .portalLoginRequired, .emptyPortalLevel:
            .portals
        }
    }

    /// The large title under which it sits — as a language key of the phone.
    ///
    /// Not the name of the state: above "This library is empty" sits "My
    /// Library", because that is the screen one is on.
    var hostTitle: String {
        switch host {
        case .start: "tab.home"
        case .library: "tab.library"
        case .live: "tab.live"
        case .portals: "tab.portals"
        case .search: "tab.search"
        case .downloads: "stock.offline"
        default: "tab.home"
        }
    }
}

extension DisruptionInterpretation {

    /// The interpretation **with what the phone knows** — the thin mapping onto the
    /// shared version.
    ///
    /// - Parameters:
    ///   - herkunft: which source was asked. The downloads belong to the media server, the
    ///     channel list to the provider.
    ///   - netz: the network path, if anyone knows it. `nil` means "not checked",
    ///     **not** "no network". If it does not hold, the phone shows
    ///     ``PlaybackPhase/networkAirplaneMode`` — with the downloads as the answer.
    ///
    /// **Without a certificate question**, and that is deliberate: on the phone nobody picks a
    /// left-over question out of the mailbox. Passing it in would mean that after a single
    /// question every error appeared as an open certificate question.
    static func state(
        forItem error: any Error, origin: Catalog.Origin, network: NetworkPath? = nil,
        address: URL? = nil, certificateTrustedByAppOnly: Bool = false
    ) -> PlaybackPhase {
        state(
            forItem: error, source: origin.source, address: address,
            certificateTrustedByAppOnly: certificateTrustedByAppOnly,
            offline: network.map(\.carries) == false ? .networkAirplaneMode : nil)
    }
}

extension Catalog.Origin {

    /// The source, as the shared interpretation needs it.
    var source: DisruptionInterpretation.Source {
        switch self {
        case .jellyfin, .downloads: .jellyfin
        case .provider, .channelList: .provider
        case .portals: .portals
        }
    }
}
