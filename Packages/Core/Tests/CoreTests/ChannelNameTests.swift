import Foundation
import Testing

@testable import Core

/// How a channel name from an IPTV provider turns into something readable.
///
/// **Every name here is real.** They come from the catalog of a commercial provider
/// with 5389 channels, queried on 2026-07-28. Invented examples would have concealed
/// exactly the peculiarities this is about — none of them would have occurred to
/// anyone on their own.
@Suite("Making channel names readable")
struct ChannelNameTests {

    // MARK: - Anzeige

    @Test("Superscript characters become ordinary letters")
    func foldsSuperscripts() {
        // The core of the matter: 40 percent of the names in the catalog carry such
        // characters. Untreated, `ᴴᴰ` would appear on the TV — readable, but in a font not
        // made for it, and unreachable for any search.
        #expect(ChannelName.display("PERLE: 3TAL ᴿᴬᵂ") == "PERLE: 3TAL RAW")
        #expect(ChannelName.display("DE: SELVA INFO ᴿᴬᵂ") == "DE: SELVA INFO RAW")
        #expect(ChannelName.display("FR: CANOT+ LIVE 5 ᴿᴬᵂ") == "FR: CANOT+ LIVE 5 RAW")
    }

    @Test("Superscript digits become digits")
    func foldsSuperscriptDigits() {
        // `⁶⁰ᶠᵖˢ` stands for 60 frames per second. Written as a number it can be read and
        // found.
        #expect(ChannelName.display("PERLE ᴿᴬᵂ ⁶⁰ᶠᵖˢ").contains("60fps"))
        #expect(ChannelName.display("DE| SOLA SPORT AUSTRIA ⁴ᴷ & INF").contains("4K"))
    }

    @Test("A lowercase letter produced by case folding is smoothed out")
    func smoothsFoldingArtifact() {
        // Unicode has no superscript capital Y, so providers use the small one. Without
        // normalization `DOLBy AUDIO` would appear — that looks like a typo of the program,
        // not like one of the provider.
        #expect(
            ChannelName.display("DE| WELLE ENTERTAINMENT ᴴᴰ ᴰᴼᴸᴮʸ ᴬᵁᴰᴵᴼ")
                == "DE| WELLE ENTERTAINMENT HD DOLBY AUDIO")
    }

    @Test("Real names with mixed case stay untouched")
    func leavesGenuineMixedCaseAlone() {
        // The reason the normalization works character by character and not over the whole
        // word: All these names appear like that in the catalog and contain not a single
        // superscript character. A rule "predominantly uppercase, so everything uppercase"
        // would have destroyed them — with `KıRGıN`, because of the Turkish dotless i, even
        // into a different word.
        for name in ["KışFM", "TozFM", "KulaRFM", "DUMANMiX", "HiSAR", "KıRGıN", "ALP2St"] {
            #expect(ChannelName.display(name) == name, "\(name) was changed")
        }
    }

    @Test("A frame of hash signs is dropped")
    func stripsHashFrame() {
        #expect(ChannelName.display("##### SOLA HEVC #####") == "SOLA HEVC")
        #expect(ChannelName.display("### SKYGO SPORT VIP ###") == "SKYGO SPORT VIP")
    }

    @Test("A trailing character is dropped, a character in the middle of a word is not")
    func stripsOnlyTrailingSymbols() {
        // `◉` stands at the end of 51 channels and means nothing. But a provider writes
        // `Pusula SP⚽RTS 3` — there the character replaces a letter. Anyone who removed
        // characters across the board would get `Pusula SPRTS`, and the channel would not be
        // recognizable.
        #expect(
            ChannelName.display("WELLE: SOLA CINEMA HIGHLIGHTS ᴴᴰ ◉")
                == "WELLE: SOLA CINEMA HIGHLIGHTS HD")
        #expect(ChannelName.display("KIES: Pusula SP⚽RTS 3 ᴴᴰ").contains("SP⚽RTS"))
    }

    @Test("A provider typo is not silently corrected")
    func doesNotFixProviderTypos() {
        // `DE: BERGFUNK TV DE.tsCHLAND HD` appears literally like that in the catalog — the
        // period and the lowercase are an error of the provider, not folding. The cleaner
        // must not guess what was meant: A name improved on its own authority turns into a
        // channel that the user searches for under the name they see in other players.
        #expect(
            ChannelName.display("DE: BERGFUNK TV DE.tsCHLAND HD")
                == "DE: BERGFUNK TV DE.tsCHLAND HD")
    }

    @Test("A name without decoration passes through unchanged")
    func plainNamesUntouched() {
        // The most frequent case must not be the most expensive.
        #expect(ChannelName.display("DE: AHORN HD") == "DE: AHORN HD")
        #expect(ChannelName.display("ZINNE") == "ZINNE")
    }

    @Test("Empty and meaningless input yields something empty, not a crash")
    func handlesEmptyInput() {
        // Provider lists contain entries without names. A crash while reading a list of 5389
        // channels because of an empty field would be the most expensive error in this area.
        #expect(ChannelName.display("").isEmpty)
        #expect(ChannelName.display("   ").isEmpty)
        #expect(ChannelName.display("####").isEmpty)
        #expect(ChannelName.display("◉ ◉ ◉").isEmpty)
    }

    // MARK: - Suchschlüssel

    @Test("The provider prefix drops out of the search key")
    func searchKeyDropsPrefix() {
        // 1313 channels begin with `DE:`, 1113 with `TR:`. If the prefix stayed, almost every
        // German channel would begin with the same two letters and the sorting would be
        // worthless.
        #expect(ChannelName.searchKey("DE: AHORN HD") == "AHORN HD")
        #expect(ChannelName.searchKey("DE| SOLA HEVC") == "SOLA HEVC")
        #expect(ChannelName.searchKey("PERLE: 3TAL ᴿᴬᵂ") == "3TAL RAW")
    }

    @Test("The decoration can be searched")
    func searchKeyFindsDecoration() {
        // That is the practical gain: Anyone who types "HD" or "4K" also finds the channels
        // where it is written as `ᴴᴰ` and `⁴ᴷ`.
        #expect(ChannelName.searchKey("WELLE: SOLA CINEMA HIGHLIGHTS ᴴᴰ ◉").contains("HD"))
        #expect(ChannelName.searchKey("DE| SOLA SPORT AUSTRIA ⁴ᴷ & INF").contains("4K"))
    }

    @Test("Accents and Turkish dots do not disturb the search")
    func searchKeyIgnoresDiacritics() {
        // Anyone who types "yildiz" on a remote cannot produce an `ı`.
        #expect(ChannelName.searchKey("KıRGıN TV") == "KIRGIN TV")
        #expect(ChannelName.searchKey("TR: KışFM").contains("KISFM"))
    }

    @Test("A long piece before the colon is the name itself")
    func searchKeyKeepsLongPrefix() {
        // The prefixes in the catalog are two to six characters long. A long piece in front
        // belongs to the name — cutting it off would make the channel unfindable.
        let key = ChannelName.searchKey("Das Nordlicht Programm: Tagesfunke")
        #expect(key.contains("DAS NORDLICHT"))
    }

    // MARK: - Gruppenüberschriften

    @Test("A line framed on both sides is not a channel")
    func detectsSectionMarkers() {
        // Providers put headings into the channel list so that simple players show a
        // separator line. They have an identifier and an address like a channel, but deliver
        // nothing — whoever selects one sees a black picture without explanation and looks
        // for the fault in themselves.
        #expect(ChannelName.isSectionMarker("##### SOLA HEVC #####"))
        #expect(ChannelName.isSectionMarker("### WELLE SPORT ᴴᴰ ᴰᴼᴸᴮʸ ᴬᵁᴰᴵᴼ ###"))
        #expect(ChannelName.isSectionMarker("#### PERLE ᴿᴬᵂ ⁶⁰ᶠᵖˢ #####"))
    }

    @Test("An ordinary channel is not a heading")
    func plainNamesAreNotMarkers() {
        // The condition is two-sided, and that is proven across the whole catalog: Of 5389
        // channels 113 contain a hash sign, and all 113 are framed. There is no channel with
        // a hash sign in its actual name.
        #expect(!ChannelName.isSectionMarker("DE: AHORN HD"))
        #expect(!ChannelName.isSectionMarker("PERLE: 3TAL ᴿᴬᵂ"))
        #expect(!ChannelName.isSectionMarker(""))
        #expect(!ChannelName.isSectionMarker("#"))
        // One-sided is no framing — a provider could keep something like that as a name, and
        // then it would be a channel.
        #expect(!ChannelName.isSectionMarker("### SPORT 1"))
    }

    /// **The finding of 2026-08-11:** In the Turkish HEVC group the heading stood as the first
    /// "channel" in the list — with logo, with play button and without picture. It is
    /// framed just like the others, only not with hash signs: `▁▂▃▄ ULUSAL HEVC ▄▃▂▁`. The
    /// old rule asked for the hash sign and not for the shape.
    @Test("A frame of other characters is a heading too")
    func detectsFramesWithoutHashes() {
        #expect(ChannelName.isSectionMarker("▁▂▃▄ ULUSAL HEVC ▄▃▂▁"))
        #expect(ChannelName.isSectionMarker("=== SPOR ==="))
        #expect(ChannelName.isSectionMarker("★★ FILME ★★"))
    }

    /// **Two-sided remains a condition, and that is the actual subject of the check.**
    /// One-sided would hit every channel whose name begins with a character — and in such
    /// lists that happens. Letting a channel disappear is worse than one header row too
    /// many.
    @Test("A single character at the start does not make a heading")
    func decorationOnOneSideIsStillAChannel() {
        #expect(!ChannelName.isSectionMarker("▁▂▃▄ ULUSAL HEVC"))
        #expect(!ChannelName.isSectionMarker("★ SPORT 1"))
        // And a pure separator line carries no name — it is not a case for this rule but for
        // the question whether anything is there at all.
        #expect(!ChannelName.isSectionMarker("#########"))
    }

    @Test("A leading character drops out of the display")
    func displayDropsLeadingDecoration() {
        // Before, the list showed `▁▂▃▄ ULUSAL HEVC`: The trailing word was dropped, the
        // leading one stayed — and the bars looked like a picture.
        #expect(ChannelName.display("▁▂▃▄ ULUSAL HEVC ▄▃▂▁") == "ULUSAL HEVC")
        #expect(ChannelName.display("★ SPORT 1") == "SPORT 1")
        // A character in the middle of a word stays: `Pusula SP⚽RTS` is the name.
        #expect(ChannelName.display("KIES: Pusula SP⚽RTS 3 RAW") == "KIES: Pusula SP⚽RTS 3 RAW")
    }
}
