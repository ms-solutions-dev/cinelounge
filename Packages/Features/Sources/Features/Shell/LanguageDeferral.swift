import Foundation

#if canImport(UIKit)
    import UIKit
#endif

/// Holds back the rebuild after a language change **as long as something lies above the
/// shell** (final check 2026-09-25, B-1).
///
/// **The finding:** A language change rebuilds the main view via a new identifier —
/// `String(localized:)` reads at build time, and SwiftUI does not notice the change of
/// the bundle (see `RootView`). The identifier, however, hung on ``MainView`` as a
/// whole, and with it the player cover and every open sheet fell: a running movie
/// stopped, the handoff from the iPhone broke off in the middle of receiving. Since the
/// language travels with the profile, the change also comes **without** anyone
/// triggering it in the settings — via a relocation note from remote or a handoff with
/// a different language.
///
/// **Deferring instead of hanging the identifier lower, and that is the more robust of
/// the two variants.** An identifier on the content view inside ``MainView`` protected
/// the player, but not the sheets that hang **in** the content — the handoff opens from
/// the profile management in the settings, that is, from exactly the part that would be
/// rebuilt. Deferring protects everything that is presented, wherever it hangs; what is
/// asked is the system (``PresentationState/pending``) and not a list that one would
/// forget to extend with the next sheet. The price: until the movie ends, some texts
/// are in the old language. That is visible and harmless; an aborted movie is neither.
///
/// **The calculation is this type and nothing else** — the shell asks it for the
/// identifier and reports changes and state to it. That way it can be checked without a
/// screen.
public struct LanguageDeferral: Equatable, Sendable {

    /// The language that stays in place as long as something is presented — `nil` if
    /// nothing is waiting.
    public private(set) var held: String?

    public init() {}

    /// The identifier for the rebuild: the held one, otherwise the current one.
    public func identifier(current: String) -> String { held ?? current }

    /// Whether a rebuild is pending.
    public var waiting: Bool { held != nil }

    /// The language has changed, away from `old`.
    ///
    /// **If blocked, the previous one is held** — namely the one that was visible: if it
    /// changes twice while the movie is playing, the first one stays in place.
    public mutating func switchObserver(from old: String, isBlocked: Bool) {
        if isBlocked {
            if held == nil { held = old }
        } else {
            held = nil
        }
    }

    /// Check whether rebuilding is allowed now.
    public mutating func verify(isBlocked: Bool) {
        if !isBlocked { held = nil }
    }
}

/// Whether something is currently **presented** — a full screen, a sheet, a
/// confirmation.
///
/// **The system knows, SwiftUI does not say.** On tvOS, `fullScreenCover`, `sheet` and
/// `confirmationDialog` put a presented controller over the window; whether one is
/// there is the one question that is answered the same way for every sheet, also for
/// one that is only added tomorrow.
public enum PresentationState {

    @MainActor public static var pending: Bool {
        #if canImport(UIKit)
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .contains { $0.rootViewController?.presentedViewController != nil }
        #else
            false
        #endif
    }
}
