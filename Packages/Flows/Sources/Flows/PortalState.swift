import Foundation
import PortalKit

/// What state a portal is in — **shared since decision 27 (C11)**: The phone
/// shows it in its portal list, the TV in the sidebar, both before one
/// enters the portal. Each platform chooses the symbol for it in its view
/// (`Flows` knows nothing about design).
///
/// **A property of the portal, not an error message.** The difference decides where
/// the information goes: An error message appears when something has gone wrong — that is,
/// after the press. A property is in the list **before** one presses. Whoever learns the
/// state only on pressing considers the app broken; whoever sees it beforehand
/// chooses a different portal.
///
/// **Never colour alone.** Every state carries a symbol. With deuteranopia `success`
/// and `progress` are close together, and distinguishing "reachable" from "setting missing" only
/// by colour would mean: not at all.
public nonisolated enum PortalState: Sendable, Equatable {

    /// Answers and delivers.
    case ready

    /// The portal declares the capability `login` and has no credentials.
    ///
    /// On the phone typing is the cheapest operation there is — on the TV the
    /// most expensive. That is one of the reasons why the phone is meant to be the remote.
    case login

    /// The portal needs a setting that is still empty — the server sends `needs_setting`.
    ///
    /// The task is in the portal's settings: the field marked as required is filled there.
    case needsSetting

    /// Does not answer.
    case muted

    /// Something else — with the bridge's **literal** reason.
    ///
    /// "Doesn't work" is no information, "the server refused the sign-in" is. The
    /// reason text is therefore passed through and not translated.
    case other(String)

    /// From what the service sends — **the state word (`state`) and, separate from it,
    /// the reason (`reason`).**
    ///
    /// - `ready`/`ready` is ``ready``; the words for login and a missing setting
    ///   are their cases, **even without a reason text**.
    /// - Any other word — `broken`, `disabled` from the server as well as a future one
    ///   that this app does not yet know — becomes ``other(_:)`` **with a reason**: The reason
    ///   appears literally, and the portal stays selectable. **Without a reason** it is
    ///   ``muted``; a state that neither app nor service explains leads nowhere.
    ///
    /// **The reason is never the state word** (check 2026-09-27, portals B2): Until then
    /// both apps called `PortalState(reason ?? "", reason: reason)`, and a known state word
    /// without a reason ended up as "stumm".
    public init(_ word: String, reason: String? = nil) {
        switch word {
        case "bereit", "ready": self = .ready
        case "anmeldung", "anmeldung_noetig": self = .login
        case "needs_setting": self = .needsSetting
        case "stumm", "offline", "fehler": self = .muted
        default: self = reason.map(PortalState.other) ?? .muted
        }
    }

    /// From a row of the portal list.
    public init(_ row: PortalRow) {
        self = row.ready ? .ready : PortalState(row.state, reason: row.reason)
    }

    public var isReady: Bool { self == .ready }

    /// Whether this portal can be opened at all.
    ///
    /// Login and a missing setting **are** openable: There the task stands, what
    /// is to be done. Only a mute portal leads nowhere.
    public var isSelectable: Bool { self != .muted }

    /// Key in the catalog — or, for ``other``, the literal reason.
    public var key: String? {
        switch self {
        case .ready: "settings.portals.reachable"
        case .login: "portal.state.login"
        case .needsSetting: "portal.state.needs_setting"
        case .muted: "portal.state.silent"
        case .other: nil
        }
    }

    public var wording: String? {
        if case .other(let reason) = self { return reason }
        return nil
    }
}
