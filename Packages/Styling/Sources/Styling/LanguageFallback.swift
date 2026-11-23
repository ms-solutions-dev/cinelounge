import Core
import Foundation

/// The sentence for a key — **or nothing if there is none.**
///
/// **`NSLocalizedString` cannot answer this question**, and that is the reason for
/// this file: If a key is missing, it returns the key itself. For display that is
/// mostly right; for a refusal from the server it is not. There a gap should
/// appear as a **code** (`stream.geo_blocked`) and not as a key (`error.stream.geo_blocked`) —
/// the code is what stands in the server's log, and thus what someone can
/// continue searching with.
///
/// **So the fallback is detected instead of avoided:** If the key comes back
/// unchanged, there is no translation. That is a comparison and not a guess.
public enum LanguageFallback {

    /// The translated sentence, or `nil`.
    ///
    /// The second attempt with the development state is necessary because a catalog can carry a
    /// key without having translated it for **this** language — then the system
    /// delivers the base language, and that is a sentence and not a gap.
    public static func message(_ key: String) -> String? {
        let found = NSLocalizedString(
            key, bundle: AppLanguageSetting.bundles(zu: key), comment: "")
        return found == key ? nil : found
    }
}
