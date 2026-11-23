import Core
import Foundation

/// What does not go out.
///
/// The basis is the rule from `Core.Diagnostics.withoutAddress`: **where `://` occurs,
/// the whole text does not go out.** It is deliberately coarse — in a foreign
/// running text (`localizedDescription`, an `NSError` dump) the address is stuck somewhere
/// in the middle and cannot be cut out safely. The occasion was a submitted
/// report that carried the provider credentials in plain text **in the path**, where none of the then-current
/// protection rules looked.
///
/// Here two cases are added that exist only on the phone:
///
/// * **File paths of the downloads** carry the title name. Whoever sees that someone
///   downloaded `Woujeinspes Skutgro S01E04` knows more than an error report
///   should reveal.
/// * **Keychain messages** carry the account identifier.
///
/// Both are caught as coarsely as the address, and for the same reason: a pattern
/// that hits only the dangerous cases will eventually miss one.
public enum Redaction {

    /// Turns any text into one that may go out.
    public static func sanitized(_ text: String) -> String {
        let withoutAddress = Diagnostics.withoutAddress(text) ?? ""
        return withoutPaths(withoutAddress)
    }

    /// Replaces paths with `(Pfad)` and keeps at most the extension.
    ///
    /// The extension stays because it helps when searching and reveals nothing about the title:
    /// `.mp4` says that it was a video, `(Pfad).mp4` does not say which.
    ///
    /// **Why it does not split on spaces — the bug that the test caught:**
    /// a first attempt replaced word by word. From
    /// `/var/mobile/Vorrat/Woujeinspes Skutgro S01E04.mp4` that made
    /// `(Pfad) Skutgro S01E04.mp4` — the title was still there. File names carry
    /// spaces, and a pattern that splits on them misses exactly the part that
    /// matters.
    ///
    /// What is caught is therefore **from the slash to the first file extension**, spaces
    /// included. That occasionally hits a few words too many; that is the
    /// right direction in which to err — the same consideration as with the
    /// `://` rule in `Core`.
    public static func withoutPaths(_ text: String) -> String {
        guard text.contains("/") else { return text }

        var text = text
        if let pattern = try? NSRegularExpression(pattern: #"/\S[^\n]*?\.([A-Za-z0-9]{1,5})\b"#) {
            text = pattern.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text),
                withTemplate: "(path).$1")
        }

        // What still carries a slash afterwards is a path without an extension.
        return text.split(separator: " ", omittingEmptySubsequences: false)
            .map { $0.contains("/") ? "(path)" : String($0) }
            .joined(separator: " ")
    }
}
