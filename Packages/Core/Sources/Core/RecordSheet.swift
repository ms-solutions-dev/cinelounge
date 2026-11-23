import Foundation

/// A set of fields as JSON in a ``KeyValueStore`` — **the form that ``FileStore``
/// means.**
///
/// **Why this exists and why not six lines in every type.** Storing a structure in a
/// string store forces a decision: delimiters or JSON. Delimiters have already caused damage
/// three times in this project — `;` against `\n`, U+001F against `\t`, and `fresh:from` in one
/// word, because "`UserDefaults` does not tolerate nested dictionaries". Each time the
/// character was chosen correctly and was still wrong, because the **other side** took a
/// different one.
///
/// Here the decision is made once: JSON, readably indented, keys sorted. Indented, because a
/// file should be viewable — that was one of the reasons to make it a file. Sorted, so that
/// two equal states look equal; otherwise a comparison would depend on the whim of the
/// dictionary.
///
/// **Unreadable yields `nil` and no error.** ``FileStore`` cannot leave a half file behind
/// — it writes completely and replaces. But something can still be written into it by hand,
/// and then "like new" is the only answer that takes nobody's setting away.
public enum RecordSheet {

    /// Reads a stored set of fields.
    public static func read<Content: Decodable>(
        _ contentType: Content.Type = Content.self, under key: String, from store: any KeyValueStore
    ) -> Content? {
        guard let text = try? store.value(for: key), let raw = text.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(Content.self, from: raw)
    }

    /// Writes a set of fields.
    ///
    /// **A failure stays silent and is still visible:** ``FileStore`` reports at startup if it
    /// may not write anywhere. Reporting individually here would mean writing the same line on
    /// every keystroke.
    public static func write(
        _ content: some Encodable, under key: String, in store: any KeyValueStore
    ) {
        let writer = JSONEncoder()
        writer.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let raw = try? writer.encode(content),
            let text = String(data: raw, encoding: .utf8)
        else { return }
        try? store.set(text, for: key)
    }

    /// **Nothing remembered means: no entry.** A file with an empty list says the same thing
    /// and looks like a setting that nobody made.
    public static func cleanUp(_ key: String, in store: any KeyValueStore) {
        try? store.remove(key)
    }
}
