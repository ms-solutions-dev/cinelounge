import Foundation

/// **What an unseen episode may show** (AP85 binge package, 2026-11-09).
///
/// With ``BingePreferences/hidesSpoilers`` on, an episode that has neither been watched
/// nor started shows its still blurred and no description — the still of episode 8 is often
/// the scene the season builds towards. The title stays: without it the list could not be
/// read. **One rule for TV and phone**, so that both hide the same episodes.
public enum SpoilerGuard {

    /// How strongly the still is blurred: shapes and colors stay, faces and scenes do not.
    public static let blurRadius: Double = 24

    public static func hides(watched: Bool, started: Bool, enabled: Bool) -> Bool {
        enabled && !watched && !started
    }

    /// For a catalog title: only episodes are protected — a film's image is its poster.
    public static func hides(_ item: MediaItem, enabled: Bool) -> Bool {
        guard item.kind == .episode else { return false }
        return hides(
            watched: item.progress?.isWatched == true,
            started: (item.progress?.position ?? 0) > 0,
            enabled: enabled)
    }
}
