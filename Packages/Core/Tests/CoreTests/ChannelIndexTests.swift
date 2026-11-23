import Testing

@testable import Core

/// **An index over 7,746 channels** — AP32, from E80, 2026-09-24.
///
/// The checks hold the five decisions that make the difference between an index and a
/// dummy. Four of them are verified in the catalog, not guessed.
@Suite("The channel index")
struct ChannelIndexTests {

    /// **The most expensive error, and it would have been invisible.**
    ///
    /// ``ChannelName/searchKey(_:)`` records that without cutting off the prefix "1313
    /// channels begin with `DE`". An index over the **display name** would thus have had
    /// exactly **one** letter at the core of the catalog — and it would have looked
    /// completely right.
    @Test("The provider prefix does not count")
    func prefixDoesNotCount() {
        #expect(ChannelIndex.letter("DE: RENDAL") == "R")
        #expect(ChannelIndex.letter("DE | Sela.1") == "S")
        // And a colon in the name itself stays — the same boundary as in `searchKey`.
        #expect(ChannelIndex.letters(["DE: RENDAL", "DE: AHORN", "DE: ZINNE"]) == ["A", "R", "Z"])
    }

    /// **Articles are not stripped — unlike in the library.**
    ///
    /// There "Der Pakuro" is filed under P because the article belongs to the title. A
    /// channel, by contrast, is called what it is called. Whoever files "Das Nordlicht" under
    /// E has attached a correct rule to the wrong thing.
    @Test("A channel name keeps its article")
    func articleStays() {
        #expect(ChannelIndex.letter("Das Nordlicht") == "D")
        #expect(ChannelIndex.letter("The Lantern TV") == "T")
    }

    /// Digits gather under one character, **and that stands at the end.**
    @Test("Whatever does not start with a letter goes last under #")
    func digitsGoLastUnderHash() {
        #expect(ChannelIndex.letter("3tal") == "#")
        #expect(ChannelIndex.letter("13th Street") == "#")
        #expect(ChannelIndex.letters(["3tal", "AHORN", "ZINNE"]) == ["A", "Z", "#"])
    }

    /// **Only occupied letters** — a jump into the void is worse than no jump.
    @Test("Empty letters are not offered")
    func emptyOnesDropOut() {
        let register = ChannelIndex.letters(["AHORN", "Avena", "ZINNE"])
        #expect(register == ["A", "Z"])
        #expect(!register.contains("B"))
    }

    /// **A group heading does not occupy a letter.**
    ///
    /// Providers put them in the middle of the list; they look like channels and deliver
    /// nothing. A letter that only a heading occupies leads to an entry that cannot be
    /// played — the press would be in vain and the reason invisible.
    @Test("Group headings do not occupy a letter")
    func headingsDoNotCount() throws {
        // First prove that the sample really is a heading — otherwise the rest checks
        // nothing.
        let tag = "### UNTERHALTUNG ###"
        try #require(ChannelName.isSectionMarker(tag))

        #expect(ChannelIndex.letters(["AHORN", tag]) == ["A"])
    }

    /// **Turkish and accented names do not fall behind Z.**
    ///
    /// ``ChannelName/searchKey(_:)`` already takes care of that by resolving accents — "Ç"
    /// becomes "C", "KıRGıN" becomes "KIRGIN". As raw values both sorted behind "Z"
    /// (finding 2026-08-07 on a Turkish category); the question is therefore already
    /// answered here, and this check holds that it stays answered.
    @Test("Accents sort under their base letter")
    func accentsMatchBaseLetter() {
        #expect(ChannelIndex.letter("Çakılo TV") == "C")
        #expect(ChannelIndex.letter("Ölmezo TV") == "O")
        #expect(ChannelIndex.letters(["Çakılo TV", "CORA"]) == ["C"])
    }

    /// **The letter is not a search word.**
    ///
    /// The search checks whether the name **contains** the word; with "R" "Sport R" would
    /// come along too. An index that shows more than its letter is none.
    @Test("A letter only matches the start")
    func letterMatchesOnlyTheStart() {
        #expect(ChannelIndex.matches("RENDAL", zu: "R"))
        #expect(!ChannelIndex.matches("Sport R", zu: "R"))
    }

    // MARK: - Die beiden Filter

    /// **Both at once yield an empty list without a recognizable reason.**
    ///
    /// Letter "R" and search word "Sport": each has hits on its own, together none — and
    /// one does not see the search field and the chosen mark at the same time as the
    /// cause.
    @Test("A search term cancels the letter")
    func searchTermCancelsLetter() {
        var filter = ChannelFilter()
        filter.select("R")
        filter.search("Sport")
        #expect(filter.letter == nil)
        #expect(filter.searchTerm == "Sport")
    }

    @Test("A letter cancels the search term")
    func letterCancelsSearchTerm() {
        var filter = ChannelFilter()
        filter.search("Sport")
        filter.select("R")
        #expect(filter.searchTerm.isEmpty)
        #expect(filter.letter == "R")
    }

    /// **A cleared field takes no letter along.**
    ///
    /// Whoever clears the search field wants to see the whole list — not additionally lose
    /// an index that they may just have set. A letter that disappears when the last
    /// character is deleted looks like a bug.
    @Test("An empty search term leaves the letter in place")
    func emptySearchTermKeepsTheLetter() {
        var filter = ChannelFilter()
        filter.select("R")
        filter.search("")
        #expect(filter.letter == "R")
    }

    /// **The same letter twice cancels it** — otherwise the only way back to the whole list
    /// would be clearing a field in which nothing stands.
    @Test("A second press on the same marker cancels it")
    func secondPressCancels() {
        var filter = ChannelFilter()
        filter.select("R")
        filter.select("R")
        #expect(filter.letter == nil)
    }

    @Test("Another letter replaces the previous one")
    func otherLetterReplaces() {
        var filter = ChannelFilter()
        filter.select("R")
        filter.select("S")
        #expect(filter.letter == "S")
    }

    /// And the filter lets through exactly what it should.
    @Test("The letter matches the start, the search term also the middle")
    func passIsDifferent() {
        var filter = ChannelFilter()
        filter.select("R")
        #expect(filter.letsPass(rawName: "DE: RENDAL", key: "RENDAL"))
        #expect(!filter.letsPass(rawName: "DE: Sport R", key: "SPORT R"))

        filter.search("R")
        #expect(filter.letsPass(rawName: "DE: RENDAL", key: "RENDAL"))
        // The search checks "contains" — that is exactly why it is not an index.
        #expect(filter.letsPass(rawName: "DE: Sport R", key: "SPORT R"))
    }

    /// Ohne beides kommt alles durch.
    @Test("An empty filter lets everything through")
    func emptyFilterPassesEverything() {
        let filter = ChannelFilter()
        #expect(filter.letsPass(rawName: "DE: RENDAL", key: "RENDAL"))
        #expect(filter.letsPass(rawName: "3tal", key: "3TAL"))
    }
}
