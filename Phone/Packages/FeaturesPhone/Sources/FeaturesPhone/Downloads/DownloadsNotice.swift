import Core
import Diagnose
import Foundation

#if canImport(UserNotifications)
    import UserNotifications
#endif

/// A notification when a download is finished — **and no other.**
///
/// **One occasion and not "notifications".** The roadmap demanded them without saying what for;
/// after thinking it through, exactly **one** case remains in which the viewer learns something
/// they do not already see: a film loads for ten minutes, the app is in the pocket, and then it
/// is there. Everything else — a failure, a paused job — is in the downloads screen and is read
/// when you look; a notification for that would be an interruption for information that can
/// wait.
///
/// **The prompt comes at the first download and not at launch.** A prompt that appears the
/// first time an app is opened answers a question nobody asked — and is therefore tapped away.
/// Anyone who has just pressed "Download" understands it. The same consideration as with the
/// camera in the handoff.
///
/// **A no stays a no.** Anyone who declines is not asked again; iOS would not show the second
/// prompt anyway, and the app does not pretend it could.
///
/// **It lives here and not in the downloads package.** `Downloads` also runs on the computer
/// (`swift test`), and `UserNotifications` does not exist there — an `#if` in the core of a
/// package would be the start of two versions of the same flow.
public enum DownloadsNotice {

    /// Whether it has been asked once already — so that the prompt does not come with every
    /// download.
    private static let askedKey = "stock.notificationsAsked"

    /// Asks once for permission.
    ///
    /// **Called at the first download job** and not at program start.
    public static func askOnce(_ store: UserDefaults = .standard) {
        #if canImport(UserNotifications)
            guard !store.bool(forKey: askedKey) else { return }
            store.set(true, forKey: askedKey)
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
                isAllowed, error in
                if let error {
                    Diagnose.hint(.playback, "Notifications: permission request failed", error)
                    return
                }
                Diagnose.step(
                    .playback, "Notifications: \(isAllowed ? "allowed" : "denied")")
            }
        #endif
    }

    /// Reports that a title has finished loading.
    ///
    /// **Without permission nothing happens, and silently.** An error in the ledger for every
    /// finished download for someone who has declined notifications would be a ledger full of lines
    /// about a decision that has already been made.
    ///
    /// **Background only.** Anyone who has the app open right now sees the downloads; a
    /// notification about it would be a banner above the list that already shows the same thing.
    public static func notifyDone(title: String, isInForeground: Bool) {
        #if canImport(UserNotifications)
            guard !isInForeground else { return }
            let content = UNMutableNotificationContent()
            content.title = AppLanguageSetting.text("stock.doneTitle")
            content.body = String(
                format: AppLanguageSetting.text("stock.doneBody %@"), title)
            content.sound = .default

            // **No trigger means immediately.** A time trigger of one second would be a second in which
            // the app can be terminated.
            let job = UNNotificationRequest(
                identifier: "downloads-done-\(title.hashValue)", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(job) { error in
                if let error {
                    Diagnose.hint(.playback, "Notification not delivered", error)
                }
            }
        #endif
    }
}
