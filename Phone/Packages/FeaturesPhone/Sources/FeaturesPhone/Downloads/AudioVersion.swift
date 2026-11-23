import Foundation

/// Whether a host name means a **different audio version** and not a different source.
///
/// **The finding (E61): with the ARD the "hosts" are resolution levels.** What with
/// Serieshub is three providers of the same file is there a list like "HD 1080p",
/// "HD 1080p · Audio description", "Web M". The automatic fallback takes the next
/// entry — and the next can be the **audio-described version for the blind.**
///
/// **Why that is worse than a failure.** One resolution level lower is
/// the same picture in poorer quality; an audio description is a **different film**:
/// over the audio track lies a voice that describes what is to be seen. Whoever chose "HD 1080p"
/// and silently gets that takes it for a bug of the app — and
/// rightly so.
///
/// **By hand it stays selectable.** The fallback skips it; in the download sheet it stays
/// in the list. Whoever **wants** an audio description gets it — they just should
/// not get it without wanting it.
///
/// **By the name and not by a feature, and that is the honest limit of this rule.**
/// The bridge passes through what the portal delivers; there is no "audio version" field.
/// It is therefore recognised by the words the German media libraries use for it —
/// an English portal with "descriptive audio" would slip through. That is no oversight: a
/// list that claims to recognise everything would be a worse promise than one that says
/// whom it knows.
enum AudioVersion {

    /// The words by which the German media libraries mark a secondary version.
    ///
    /// **Compared in lower case and with `contains`**, because they stand in the middle of the name:
    /// "HD 1080p · Audiodeskription", "Das Nordlicht (Hörfassung)".
    static let secondaryWords = [
        "audiodeskription",
        "hörfassung",
        "hoerfassung",
        "klare sprache",
        "leichte sprache",
        "originalton mit untertiteln",
    ]

    /// Whether this entry is a secondary version.
    static func isSecondaryVersion(_ name: String) -> Bool {
        let lowercased = name.lowercased()
        return secondaryWords.contains { lowercased.contains($0) }
    }
}
