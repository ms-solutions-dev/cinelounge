import Core
import Foundation
import JellyfinKit
import PlaylistKit
import PortalKit

/// Which screen belongs to a failure — **one table, one order, for
/// both devices.**
///
/// **The finding that led to this (phone, 2026-09-06):** `PlayerModel` translated
/// **every** error of **every** source into "No response from the media server". Over an
/// Xtream broadcast there was therefore a message that sends the viewer to the wrong
/// place.
///
/// **Why it is shared** (AP58 R3, report A finding S5). Until 2026-09-26 it existed
/// twice, and the versions drifted apart: the phone interpreted an Xtream 401
/// as an expired sign-in at the media server, the TV knew the certificate prompt
/// and the rejections of the portal service, the phone the own gaps of the sources — and
/// both checked in a **different order**. The platforms now only pass in
/// what they know (``Source``, whether the network is missing, the mailbox); what follows
/// from it lives here.
///
/// **The order, and why the TV's** (decision 20, TV benchmark — and
/// here not just a benchmark but the better reason):
///
/// 1. **What the error itself knows** (``CarriesState``) — a configured source that
///    is missing, a channel the list no longer carries. That is a fact about this
///    device, and no network situation changes it.
/// 2. **What the other side answered** — a 401 from the media server or the
///    provider, a code of the portal service, a 404 or 500 of the media server. Whoever
///    answered was reachable; the answer is more precise than any guess about the
///    network.
/// 3. **Whether this device has a network at all.** The phone checked this first ("the app
///    has tried nothing"). For an error without an answer that is true and still applies; for
///    an answer that is already there it is not: an expired token stays expired, even
///    if the network is missing right now, and the button there is the one with which the viewer
///    can change something. The quiet path into the downloads is still there on the phone — the
///    expired sign-in carries it.
/// 4. **A leftover certificate prompt** — after the network, because without a network it is no
///    information about the present, and before the origin, because with a network it is the most precise.
/// 5. **The origin** — who was asked, and whether the engine broke off.
///
/// **Pure logic.** Whoever rebuilds the interpretation at the call site builds it differently the second time;
/// here a test suite can walk it completely without building an interface.
public nonisolated enum DisruptionInterpretation {

    /// Which source was asked — **since AP58 R6 the one ``Core/Origin``.**
    ///
    /// Until 2026-09-26 there was an own enumeration here with the same three cases, because
    /// origin existed only on the TV. Since it lives in `Core`, it would be a second
    /// name for the same question. The phone maps `Catalog.Origin` (with downloads and
    /// channel list) onto it in one line.
    public typealias Source = Origin

    /// - Parameters:
    ///   - fehler: what was thrown.
    ///   - quelle: which source was asked.
    ///   - ausDemSpieler: whether the failure came from the **playback engine** and not from
    ///     the source. An error that is ``EngineDropout`` counts the same.
    ///   - adresse: the address that was not running. It distinguishes a raw
    ///     transport stream from a connection in use.
    ///   - zertifikatNurAppVertraut: whether the address is `https` and **only the app**
    ///     trusts its certificate — reported by the caller and never guessed.
    ///   - ohneNetz: **The state this platform shows when the device has no
    ///     network** — ``PlaybackPhase/noConnection`` on the TV, ``PlaybackPhase/networkAirplaneMode`` on the
    ///     phone —, or `nil` if the network is there or unknown. The guard may only
    ///     deny: "connected" does not mean the server is running.
    ///   - zertifikatsfrage: the mailbox of the connection delegate, or `nil`.
    ///     **Passed in and not grabbed globally:** checks run concurrently,
    ///     and a shared mailbox turns two checks into one.
    public static func state(
        forItem error: any Error, source: Source, fromPlayer: Bool = false,
        address: URL? = nil, certificateTrustedByAppOnly: Bool = false,
        offline: PlaybackPhase? = nil, certificatePrompt: CertificatePrompt? = nil
    ) -> PlaybackPhase {
        if let own = (error as? any CarriesState)?.state { return own }
        if let hasAnswered = remoteResponse(error) { return hasAnswered }
        if let offline { return offline }
        if certificatePrompt?.current != nil { return .certificateUnconfirmed }

        let fromEngine = fromPlayer || error is any EngineDropout
        switch source {
        case .jellyfin:
            if certificateTrustedByAppOnly { return .certificateSystemPlayer }
            if fromEngine { return .jellyfinWontPlay }
            return .networkJellyfin

        case .provider:
            if fromEngine, isRawStream(address) { return .xtreamRawStreamOnly }
            if fromEngine { return .xtreamBusy }
            return .networkXtream

        case .portals:
            switch error {
            case PortalBridge.TestError.rejected, PortalBridge.TestError.cancelled:
                return .portalUnresolvable
            default: break
            }
            if fromEngine { return .portalAddressExpired }
            return .networkPortals
        }
    }

    /// The sentence on the screen for a rejection — as a key.
    ///
    /// **Here `ErrorSummary` merges with this table instead of standing beside it.**
    /// `ErrorSummary` does not know which source was asked. **The state takes precedence
    /// because it knows more** — only for the three `network…` cases does `ErrorSummary` remain the
    /// finer tool: it distinguishes timeout, name resolution and certificate.
    /// ``PlaybackPhase/noConnection`` expressly does not belong to them: `ErrorSummary` interpreted
    /// the error there as an assertion about a server that the device could not
    /// reach at all.
    ///
    /// - Returns: a key — from the shared catalog (`state.*`, `error.*`).
    public static func rejection(
        forItem error: any Error, source: Source, fromPlayer: Bool = false,
        offline: PlaybackPhase? = nil
    ) -> String {
        let currentState = state(
            forItem: error, source: source, fromPlayer: fromPlayer, offline: offline)
        switch currentState {
        case .networkJellyfin, .networkXtream, .networkPortals:
            return ErrorSummary.key(forItem: error)
        default:
            return currentState.form.headline ?? currentState.form.message
                ?? ErrorSummary.key(forItem: error)
        }
    }

    /// Whether this address is a raw transport stream.
    ///
    /// **By the extension and not by the content type.** The content type would only come from
    /// a request, and with an account with **one** allowed connection that costs exactly
    /// the connection in question. The extension was set by the app itself.
    public static func isRawStream(_ address: URL?) -> Bool {
        guard let address else { return false }
        return ["ts", "mpegts", "mts"].contains(address.pathExtension.lowercased())
    }

    /// What the other side answered — **the error type names the source**, nothing is
    /// guessed here.
    ///
    /// * **Every sign-in has its own way back** (AP39; on the phone AP58 wave 1):
    ///   an Xtream 401 leads to the channel lists and not into the media server account, and this
    ///   also holds when a collective caller reports it as a media server failure.
    /// * **The portal service says what it lacks** (finding 2026-09-19) — by the code and not by the
    ///   status, because `401` leaves open whether the person or the device is missing.
    /// * **The media server that answers and does not get any further** (404, 400, 500) is
    ///   a malfunction at the server and not a network error — ``PlaybackPhase/forItem(_:)``. Until
    ///   2026-09-26 only the TV's Home screen knew this difference; the
    ///   phone reported "No response from Jellyfin" for it.
    ///
    /// - Returns: `nil` if it was not an answer — then the rest decides.
    private static func remoteResponse(_ error: any Error) -> PlaybackPhase? {
        if let jellyfin = error as? JellyfinSource.SourceFailure,
            jellyfin != .unreachable
        {
            return PlaybackPhase.forItem(jellyfin)
        }
        if case XtreamClient.Failure.unauthorized = error { return .xtreamAccessExpired }
        switch (error as? PortalBridge.TestError)?.code {
        case "auth.profile_required": return .portalProfileRequired
        case "auth.required": return .portalLoginRequired
        default: return nil
        }
    }
}

/// An error that **itself knows** which state belongs to it.
///
/// For the gaps a platform finds in its own sources: on the phone
/// `CompositePlayerSource.Missing` says "no source configured", `ChannelPlayerSource.Missing`
/// "the access no longer carries this channel". **A protocol and no list of types
/// here**, because these types belong to the platform; the interpretation only asks whether one
/// gives information — and asks it first (see ``DisruptionInterpretation``).
public protocol CarriesState: Error {
    nonisolated var state: PlaybackPhase { get }
}

/// A breakdown in the **playback engine** and not in the source.
///
/// The phone throws `PlayerModel.Dropout` for it, the TV reports it as a flag
/// (`fromPlayer`). Both mean the same: the server answered.
public protocol EngineDropout: Error {}

extension PlaybackPhase {

    /// Which state belongs to which failure of the media server.
    ///
    /// **Three cases collapse into one, and that is intended:** 404, 400 and 500
    /// mean the same to the viewer. **Only what has the same action is merged**;
    /// "no answer" stays separate, because there one checks the network
    /// and not the server.
    public nonisolated static func forItem(_ failure: JellyfinSource.SourceFailure) -> PlaybackPhase {
        switch failure {
        case .unauthorized: .loginExpired
        case .unreachable: .networkJellyfin
        case .notFound, .badRequest, .server: .jellyfinDisruption
        }
    }
}
