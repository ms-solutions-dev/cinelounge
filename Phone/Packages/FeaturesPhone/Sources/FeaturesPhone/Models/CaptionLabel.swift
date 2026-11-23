import Foundation

/// Where the text of a label comes from.
///
/// **The place where the closed enumerations are broken.** `Tab` and `Regalart` carried
/// their label as a catalog key, because there were only a handful of fixed names. A
/// library discovered at runtime, however, is called what the server calls it — "Home
/// videos and pictures", maybe also "Holiday 2019". This name is **not translatable and
/// must not be**: It is the server's information and not the app's.
///
/// Hence two cases and not one `String`: A fixed area has to be translated, a discovered
/// catalog must never be. Whoever kept both in one field would have to guess at every
/// display spot which of the two is present.
public enum CaptionLabel: Sendable, Hashable, Codable {
    /// Stored case names keep their original (German) form — renaming them would
    /// make data written by earlier versions unreadable (AP85 B4).
    private enum CodingKeys: String, CodingKey {
        case key = "schluessel"
        case wording = "wortlaut"
    }

    /// A key in the language catalog — for everything the app names itself.
    case key(String)

    /// Wording as it came in — for everything a service names.
    case wording(String)

    /// The text without translation. **Only for tests and sorting**, never for display: A key
    /// on the screen is an error you can see.
    public var raw: String {
        switch self {
        case .key(let text), .wording(let text): text
        }
    }

    /// The text as it belongs on the screen.
    ///
    /// **For the places where it is composed with something else** — "Live · 4" stands in
    /// **one** text, not in two side by side: Two `Text` with a separator between them wrap at
    /// the wrong place with large type.
    ///
    /// **Where nothing is composed, `Text(appKey:)` is still right.** It keeps the translation
    /// in the view, and `scripts/strings.py` finds the key there just the same.
    @MainActor
    public var readable: String {
        switch self {
        case .key(let name): SettingsModel.text(name)
        case .wording(let text): text
        }
    }
}
