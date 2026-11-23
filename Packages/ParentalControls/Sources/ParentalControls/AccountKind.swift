import Foundation

/// Adult or child — **a property of the account, not of the device.**
///
/// **Decided on 06.09. (question 3, answer c): both, and kept separate.** A child account
/// says **who owns the progress** — which episode counts as watched, who fills "Continue
/// Watching", whose markers these are. What is **locked** right now, by contrast, hangs on
/// the device (``ChildMode``).
///
/// **Only this version carries both cases**, and both occur:
///
/// * A child has a Jellyfin account of its own and gets the parent's phone — the account is
///   adult, and it must be locked anyway.
/// * A child account stands open, and the parent is sitting in front of it — then there is
///   nothing to lock, and the progress still belongs to the child.
///
/// The source had so far committed itself indecisively: `AccountRow` drew a child account as
/// an account property, `SettingsModel` derived the state of the whole lock from
/// `accounts.contains(where: \.kind)` — both account-bound --, while this package looked like
/// device state.
public enum AccountKind: String, Sendable, Equatable, CaseIterable, Codable {
    case adult = "erwachsen"
    case kind

    /// Whether this account brings a limit of its own.
    ///
    /// **It does not replace the device state.** Both apply, and what is locked is whatever
    /// **either one** locks — see ``ParentalControls/applies``.
    public var bringsLimit: Bool { self == .kind }
}
