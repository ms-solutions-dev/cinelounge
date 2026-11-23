import Diagnose
import Downloads
import UIKit

/// Receives the system's wake message — **the one thing that works only here.**
///
/// **Why the app target and not the package.** When iOS wakes a **terminated** app because
/// a task of its background session is done, it calls
/// `application(_:handleEventsForBackgroundURLSession:completionHandler:)` on the
/// `UIApplicationDelegate`. A package has none; the app target has exactly one. `Downloads`
/// therefore says **what** it needs (``WakeNotice``), and here it is delivered.
///
/// **Without this file, downloading worked only in the foreground** and within the deadline
/// iOS gives a displaced app — not across a restart. That is exactly how it has stood
/// explicitly in the source and in the schedule since 2026-09-08, so that nobody assumes more
/// than there is.
///
/// **The target stays thin.** Things are plugged together here and not decided: the
/// completion is passed on, and when it is called is decided by the session — namely only
/// once it has delivered everything.
final class WakeService: NSObject, UIApplicationDelegate {

    /// Keeps the completion and **then rebuilds the session of the identifier**
    /// (shell check H6): only a session with the same identifier gets the events delivered. In
    /// this order, so that the message "everything delivered" already finds the completion.
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        // **Keep and do not call immediately.** Whoever reports immediately cuts off the time in
        // which the bytes would still have to be written away; whoever does not report at all is
        // woken later next time, or not at all.
        //
        // The completion belongs on the main thread — UIKit demands that, and the wake message
        // calls it there.
        let finish: @MainActor @Sendable () -> Void = { completionHandler() }
        Task {
            await WakeNotice.arrived(identifier: identifier, finish: finish)
            URLBlockFetcher.reconnect(identifier: identifier)
        }
    }

    // MARK: - Die stillen Pushes von CloudKit (AP43)

    /// **Here and not in a second delegate.** SwiftUI permits exactly one
    /// `@UIApplicationDelegateAdaptor`; a second would displace this one, and then reloading in
    /// the background would again work only in the foreground. Two tasks, one place — the
    /// reasoning above applies to both lines.
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: any Error
    ) {
        Diagnose.hint(.network, "Cloud: no push registration", error)
    }

    func application(
        _ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        guard let cloud = CloudStartup.cloud else { return .noData }
        return await cloud.process(push: userInfo) ? .newData : .noData
    }
}
