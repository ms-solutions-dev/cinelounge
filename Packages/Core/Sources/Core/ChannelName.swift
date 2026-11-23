import Foundation

/// Turns an IPTV provider's channel name into something readable and something
/// searchable.
///
/// **Why this is needed**, measured on a real provider's catalog: 2176 of
/// 5389 names — 40 percent — carry superscript Unicode decoration characters.
///
/// ```
/// #### PERLE ᴿᴬᵂ ⁶⁰ᶠᵖˢ #####
/// WELLE: SOLA CINEMA HIGHLIGHTS ᴴᴰ ◉
/// DE| WELLE ENTERTAINMENT ᴴᴰ ᴰᴼᴸᴮʸ ᴬᵁᴰᴵᴼ
/// ```
///
/// Typing "3sat" still finds `PERLE: 3SAT ᴿᴬᵂ`. But every search for "HD"
/// or "4K" comes up empty, because the names contain `ᴴᴰ` and `⁴ᴷ` — different
/// characters with different code points. And sorting puts them behind everything else.
///
/// **Two separate results, deliberately.** ``display(_:)`` folds the
/// decoration into readable letters, ``searchKey(_:)`` additionally clears away
/// everything that gets in the way of searching. A single "cleaned name" for both would be wrong:
/// for search it would have to discard `RAW`, for display it must not — it
/// distinguishes two feeds of the same channel.
public enum ChannelName {

    // MARK: - Anzeige

    /// The name as it should appear on screen.
    ///
    /// The decoration is **folded, not deleted**: `ᴴᴰ` becomes `HD`, not
    /// nothing. Deleting would be more convenient and would destroy information — `RAW`, `4K`,
    /// `DOLBY AUDIO` and `60fps` tell the viewer which of several
    /// feeds of the same channel they are choosing.
    public static func display(_ raw: String) -> String {
        var text = fold(raw)

        // Remove frames made of hash signs. They only occur as framing —
        // in all 113 occurrences in the test catalog on both sides — and are ornament.
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "# "))

        // A leading or trailing word made only of symbols is dropped: `◉`
        // trails 51 channels and means nothing, and a
        // Turkish list frames its lines with bar characters (`▁▂▃▄`).
        //
        // Only **at the edge and standing alone**, not everywhere: one provider writes
        // `Pusula SP⚽RTS 3` — there the symbol replaces a letter. Removing symbols
        // across the board would yield `Pusula SPRTS`.
        //
        // **The leading case was added (2026-08-11).** Until then only the trailing
        // word was dropped, and the channel list showed `▁▂▃▄ ULUSAL HEVC` — the bars
        // looked like an image and were the half-cleared frame of a
        // header line (viewer finding 2026-08-11).
        var words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        while let last = words.last, isDecoration(last) { words.removeLast() }
        while let first = words.first, isDecoration(first) { words.removeFirst() }

        return words.joined(separator: " ")
    }

    /// A word consisting only of symbols — ornament with no meaning.
    static func isDecoration(_ word: String) -> Bool {
        !word.isEmpty && !word.contains(where: \.isLetter) && !word.contains(where: \.isNumber)
    }

    // MARK: - Suche und Sortierung

    /// The key that is searched against and sorted by.
    ///
    /// Never display it — it is deliberately mangled. What gets in the way of
    /// searching is dropped here: the provider's prefix (`DE|`, `PERLE:`, `WELLE:`),
    /// all symbols, all accents. If the prefix stayed, almost every
    /// German channel would start with `DE` and the sorting would be worthless.
    public static func searchKey(_ raw: String) -> String {
        var text = display(raw)

        // Cut off the prefix: everything before the first `:` or `|`, but only if it
        // is short. If the piece before it is long, it is the name itself — for example for
        // a channel that carries a colon in its own name.
        if let cut = text.firstIndex(where: { $0 == ":" || $0 == "|" }),
            text.distance(from: text.startIndex, to: cut) <= 12
        {
            text = String(text[text.index(after: cut)...])
        }

        // Resolve accents and throw away everything that is not a letter or a number.
        // `folding` also takes the Turkish dots with it, which is right here:
        // whoever types "kirgin" should find "KıRGıN".
        let plain = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)

        let onlyWords = String(plain.map { $0.isLetter || $0.isNumber ? $0 : " " })
        let words = onlyWords.split(separator: " ", omittingEmptySubsequences: true)

        return words.joined(separator: " ").uppercased()
    }

    // MARK: - Country groups

    /// The country code of a **group** — `DE` from `DE| SPORT` and from `de | Sport` —,
    /// or `nil` if it carries none.
    ///
    /// **One rule for both devices** (AP58 R5, finding L2, 2026-09-26). Until then
    /// the TV split at the first `|` and checked the head, the phone split at `" | "` and
    /// accepted any head. So `DE|SPORT` was a country of its own on the phone, and
    /// `UFC * MMA | FIGHT` got the "country" `UFC * MMA` there. The TV's rule
    /// now applies, measured on the catalog:
    ///
    /// - **Split at the first `|`**, with or without spaces beside it — 78 of 79
    ///   groups of a checked account carry a prefix, written sometimes one way, sometimes the other.
    /// - **The head is 1–4 characters long and only letters and digits.** A vertical
    ///   bar also occurs in the middle of names; without the limit, half the name in
    ///   `SPORT | PPV EXCLUSIVE` would be the code. Four characters leave room for
    ///   three-letter country codes and for `4K`, `8K`, `RX`.
    /// - **Uppercased**, so that `de|` and `DE|` are one country.
    public static func countryCode(fromGroup group: String) -> String? {
        guard let cut = group.firstIndex(of: "|") else { return nil }
        let header = group[group.startIndex..<cut].trimmingCharacters(in: .whitespaces)
        guard (1...4).contains(header.count), header.allSatisfy({ $0.isLetter || $0.isNumber })
        else { return nil }
        return header.uppercased()
    }

    /// What follows the country code of a group — **without a code, the whole group.**
    ///
    /// The same rule as ``countryCode(fromGroup:)``: only where a code is recognised
    /// is anything cut off, otherwise `UFC * MMA | FIGHT` would be left as half a name.
    public static func groupRemainder(fromGroup group: String) -> String {
        guard countryCode(fromGroup: group) != nil,
            let cut = group.firstIndex(of: "|")
        else { return group }
        let rest = group[group.index(after: cut)...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? group : rest
    }

    // MARK: - Was gar kein Sender ist

    /// Whether the entry is a group heading and not a channel.
    ///
    /// Providers put headings in the middle of the channel list so that simple
    /// players show them as a divider:
    ///
    /// ```
    /// ##### SOLA HEVC #####
    /// ### WELLE SPORT ᴴᴰ ᴰᴼᴸᴮʸ ᴬᵁᴰᴵᴼ ###
    /// ```
    ///
    /// They have an ID and an address like any channel, but deliver
    /// nothing. Whoever selects one sees a black picture with no explanation — and looks
    /// for the fault on their own side.
    ///
    /// **The rule is checked against the whole catalog, not estimated:** of 5389
    /// channels, 113 contain a hash sign, and **all 113** are framed
    /// on both sides. There is no channel that carries a hash in its actual name —
    /// so requiring a frame on both sides is not too strict.
    ///
    /// **No longer tied to the hash sign (11.08.).** A Turkish list frames
    /// with bar characters instead of hash signs, and its header line appeared as a channel in
    /// the list — with a logo, with a play button and without a picture (viewer finding
    /// 11.08.: "only in the first group does the group appear at the top as a header").
    /// The question is therefore about the **shape**: a frame of pure symbols,
    /// on both sides, with something readable between them.
    ///
    /// **Both sides stays a condition, and that is the safeguard.** One side only would
    /// hit every channel whose name begins with a symbol — `🔴 LIVE …`
    /// and `★ SPORT` occur in such lists, and making those disappear
    /// would be worse than one header too many.
    public static func isSectionMarker(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard text.count >= 4 else { return false }

        // The frame counts as one run without spaces: `## TR| PUSULA …` has
        // two at the front, `▁▂▃▄ ULUSAL …` four.
        let leading = text.prefix { isFrame($0) }
        let trailing = text.reversed().prefix { isFrame($0) }
        guard leading.count >= 2, trailing.count >= 2 else { return false }

        // There must be a name in between. A line of nothing but symbols is
        // a divider and not a heading — it is dropped anyway, but
        // for a different reason, and that reason should not be blurred here.
        let middle = text.dropFirst(leading.count).dropLast(trailing.count)
        return middle.contains(where: \.isLetter) || middle.contains(where: \.isNumber)
    }

    /// A character that qualifies as a frame: not a letter, not a digit, not whitespace.
    private static func isFrame(_ character: Character) -> Bool {
        !character.isLetter && !character.isNumber && !character.isWhitespace
    }

    // MARK: - Falten

    /// Resolves superscript characters into ordinary letters and numbers.
    ///
    /// Unicode can do this by itself: compatibility decomposition maps
    /// `MODIFIER LETTER CAPITAL R` to `R` and `SUPERSCRIPT SIX` to `6`. A
    /// hand-written character table would be unnecessary and would have
    /// gaps with every new provider.
    ///
    /// **The one subtlety that is why this works character by character:**
    /// Unicode has no superscript capital Y. Providers therefore use the lowercase one,
    /// and `ᴰᴼᴸᴮʸ` becomes `DOLBy` — which looks like a typo. Only a letter that
    /// **itself comes from a folding** and whose predecessor is a capital
    /// is smoothed.
    ///
    /// This narrowness is the point. A blanket "mostly uppercase, so make everything uppercase"
    /// would destroy real names from the same catalog: `KışFM`, `DUMANMiX`, `HiSAR`,
    /// `KıRGıN`, `ALP2St`. With `KıRGıN` the Turkish dotless i would even
    /// produce a different word. These names contain no superscript characters
    /// and are therefore not touched here at all.
    static func fold(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count)

        for character in raw {
            let decomposed = String(character).decomposedStringWithCompatibilityMapping

            // Unchanged: no superscript character, so nothing to smooth.
            guard decomposed != String(character) else {
                out.append(character)
                continue
            }

            // Combining characters are dropped — with an accent, a free-standing
            // tick mark would otherwise remain in the name.
            let usable = decomposed.unicodeScalars.filter { !$0.properties.isDiacritic }
            let plain = String(String.UnicodeScalarView(usable))

            let previousIsUppercase = out.last?.isUppercase ?? false
            out += previousIsUppercase ? plain.uppercased() : plain
        }

        // Collapse multiple spaces: after removing ornament,
        // gaps would otherwise remain that stand out as errors on the TV.
        return out.split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
