import Diagnose
import Foundation

/// The system's wake notification — **the half of background loading that lives in the app target.**
///
/// **Why it cannot live in this package.** When iOS wakes a terminated app because
/// a task of its background session has finished, it calls
/// `application(_:handleEventsForBackgroundURLSession:completionHandler:)` on the
/// `UIApplicationDelegate`. A package has none; the app target has exactly one. So the
/// app target takes the call and files it here.
///
/// **And why the completion handler has to be kept.** The system gives the woken app
/// time until it reports that it is done — that is exactly what the handler is for. Whoever does not call it
/// is woken later or not at all next time; whoever calls it too early cuts off
/// the time in which it could still write the bytes away. That is why it is
/// **kept** and only called when the session says it is through.
///
/// **It has to be called on the main thread.** UIKit requires that; it is written here because
/// it happens in exactly one place and otherwise you would have to look it up there.
public enum WakeNotice {

    /// **An actor and not a type with a lock.** For shared mutable state the compiler
    /// demands a guarantee, and an `NSLock` next to it is not one it can
    /// check — it reported that rightly. The design is the same as in the rest of the
    /// package: whoever holds state says so in the type.
    private actor StoreSlot {
        static let shared = StoreSlot()
        private var completions: [String: @MainActor @Sendable () -> Void] = [:]

        func create(_ finish: @escaping @MainActor @Sendable () -> Void, under identifier: String) {
            completions[identifier] = finish
        }

        func take(_ identifier: String) -> (@MainActor @Sendable () -> Void)? {
            completions.removeValue(forKey: identifier)
        }
    }

    /// The app target reports: the system has woken us for this session.
    public static func arrived(
        identifier: String, finish: @escaping @MainActor @Sendable () -> Void
    ) async {
        await StoreSlot.shared.create(finish, under: identifier)
        Diagnose.step(.network, "Downloads: woken by the system for \(identifier)")
    }

    /// The session reports: everything delivered.
    ///
    /// **Without a kept completion handler nothing happens, and that is no error** — the
    /// notification arrives even when the app was in the foreground the whole time and nobody
    /// woke it.
    @MainActor
    public static func done(identifier: String) async {
        guard let finish = await StoreSlot.shared.take(identifier) else { return }
        Diagnose.step(.network, "Downloads: wake notice answered for \(identifier)")
        finish()
    }
}
