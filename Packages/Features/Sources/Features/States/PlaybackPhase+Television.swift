import Core
import Flows
import Foundation

/// What of the shared ``PlaybackPhase`` concerns **only the TV** — where it appears and how
/// the TV passes in its situation.
///
/// **Since AP58 R3 (2026-09-26) the state itself lives in `Flows`** — shape, key,
/// symbol and the interpretation of faults, the same for TV and phone. What remains
/// here is the thin mapping onto the terms of this app: the place in the sidebar, the
/// origin of a source, the network guard and the mailbox of the certificate question.
nonisolated extension PlaybackPhase {

    /// The states this TV can show — all except those of the phone.
    static var onTV: [PlaybackPhase] {
        allCases.filter { !phoneOnly.contains($0) }
    }

    /// The section in which this state appears.
    ///
    /// **By the sidebar and not by an enumeration of its own.** On the phone it is a
    /// `ViewID`, here the place the viewer selects. The phone's cases live with
    /// the media library — they are never produced here.
    var host: AppSidebar.Destination {
        switch self {
        case .loadingStart, .loadingLong, .notSetUpYet, .emptyLibrary,
            .noConnection, .networkJellyfin, .jellyfinDisruption, .loginExpired,
            .certificateSystemPlayer, .jellyfinWontPlay, .certificateUnconfirmed,
            .networkAirplaneMode, .networkTV, .abort, .cellularPaused, .cameraDenied:
            .media
        case .emptySearch: .search
        case .emptyFavorites: .favorites
        case .emptyLiveHidden, .emptyLiveWithoutList, .networkXtream, .xtreamBusy,
            .xtreamDeliversNothing, .xtreamRawStreamOnly, .xtreamAccessExpired:
            .live
        case .networkPortals, .portalAddressExpired, .portalFetchAddress, .portalUnresolvable,
            .emptyPortalLevel, .portalProfileRequired, .portalLoginRequired:
            .portals
        }
    }
}

nonisolated extension DisruptionInterpretation {

    /// Which source was asked — **``Origin``**, the term of this app.
    ///
    /// The name remains as an alias: `SourceKind` reads better at the call sites than
    /// `Origin`, and what stands behind it is the same type.
    typealias SourceKind = Origin

    /// The interpretation **with what the TV knows** — the thin mapping onto the shared
    /// version
    /// (``DisruptionInterpretation/state(forItem:source:fromPlayer:address:certificateTrustedByAppOnly:offline:certificatePrompt:)``).
    ///
    /// - Parameters:
    ///   - netz: The guard that answers "is this device on the network?". If it is missing,
    ///     the TV shows ``PlaybackPhase/noConnection``. **Passed in and not grabbed
    ///     globally**: The first attempt on 2026-09-11 disturbed the shared guard in a test, and
    ///     Swift Testing runs tests concurrently.
    ///   - zertifikatsfrage: The mailbox of the connection delegate — **only the TV passes
    ///     it in** (see ``PlaybackPhase/tvOnly``).
    static func state(
        forItem error: any Error, origin: Origin, fromPlayer: Bool = false,
        address: URL? = nil, certificateTrustedByAppOnly: Bool = false,
        network: NetworkWatch = .shared, certificatePrompt: CertificatePrompt = .shared
    ) -> PlaybackPhase {
        state(
            forItem: error, source: origin.source, fromPlayer: fromPlayer,
            address: address, certificateTrustedByAppOnly: certificateTrustedByAppOnly,
            offline: network.connected ? nil : .noConnection,
            certificatePrompt: certificatePrompt)
    }

    /// The sentence of a rejection, with what the TV knows.
    ///
    /// - Returns: a key — shared or from the app's catalog; `Text(appKey:)`
    ///   and `AppLanguageSetting.message(_:)` find both.
    static func rejection(
        forItem error: any Error, origin: Origin, fromPlayer: Bool = false,
        network: NetworkWatch = .shared
    ) -> String {
        rejection(
            forItem: error, source: origin.source, fromPlayer: fromPlayer,
            offline: network.connected ? nil : .noConnection)
    }
}

nonisolated extension Origin {

    /// The source, as the shared interpretation needs it — **the same since AP58 R6.**
    var source: DisruptionInterpretation.Source { self }
}
