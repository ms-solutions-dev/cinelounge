import Foundation
import SourceProbe
import Testing

@testable import Features

/// **The right column** — AP46, 2026-09-24.
///
/// The card itself is a view and therefore not testable; what it **decides** is. Two
/// decisions are in it, and both would be invisible as an `if` in the `body`: whether the
/// footnote points to the list, and which language key describes a scope.
@Suite("The settings card")
struct SettingsCardTests {

    // MARK: - The footnote

    /// **A pointer to a list that shows everything is a lie.** With three options and three
    /// pills the whole choice is already there; "Hold right to open the list for choosing"
    /// would then promise a way to nothing new — and the sentence loses its value at the place
    /// where it is needed.
    @Test("Everything visible means: no hint pointing to the list")
    func allOptionsVisible() {
        let spec = CardSpec(
            header: "kopf",
            statement: "Deutsch",
            pills: [CardPill("Deutsch", chosen: true), CardPill("Original")],
            optionCount: 2)
        #expect(spec.showsListHint == false)
    }

    /// The case the sentence is built for: 79 channel groups, four of them as a preview.
    @Test("More options than pills: the hint is shown")
    func moreThanVisible() {
        let spec = CardSpec(
            header: "kopf",
            statement: "46 von 79 sichtbar",
            pills: [CardPill("Sport"), CardPill("Nachrichten")],
            optionCount: 79)
        #expect(spec.showsListHint)
    }

    /// **Without a number no pointer, even without pills.** Whoever gives no options has no list
    /// behind it — otherwise they would have named it. A row that only shows a value
    /// ("Version 1.4.2") must not claim that something can be chosen there.
    @Test("Without a count of options no hint")
    func noHintWithoutNumber() {
        let spec = CardSpec(header: "kopf", statement: "1.4.2")
        #expect(spec.showsListHint == false)
    }

    /// The borderline case: no preview, but a list behind it — the pointer is then the only
    /// thing that shows the way.
    @Test("No pills but options: the hint is shown")
    func noPillsButList() {
        let spec = CardSpec(header: "kopf", statement: "3 eingerichtet", optionCount: 3)
        #expect(spec.showsListHint)
    }

    // MARK: - The wiring

    /// **The actual finding of this component.** Twenty rows are visible at the same time; if
    /// all reported their content, ``CardKey`` would take the first in the tree — the
    /// topmost of the section, wherever the focus is. The card would stand still and say the
    /// same thing for every row.
    @Test("A row without focus reports nothing")
    func noMessageWithoutFocus() {
        let spec = CardSpec(header: "kopf", statement: "Deutsch")
        #expect(CardSpec.report(spec, focused: false) == nil)
        #expect(CardSpec.report(spec, focused: true) == spec)
    }

    /// **And a row without a card reports nothing even in focus.** Otherwise the column would
    /// switch between content and emptiness while moving through a half-converted section —
    /// which looks as if it were broken, and not as if work were still missing.
    @Test("A row without a card reports nothing even when focused")
    func noMessageWithoutCard() {
        #expect(CardSpec.report(nil, focused: true) == nil)
    }

    /// **The merge takes the first non-empty one.** Exactly one row is focused, so exactly one
    /// report is there — all the others are empty and must not overwrite it. If `reduce` took
    /// the **last**, the first empty row below the focused one deleted the card again.
    @Test("Empty reports do not clear the existing one")
    func emptyDoesNotOverwrite() {
        let spec = CardSpec(header: "kopf", statement: "Deutsch")
        var reducedSpec: CardSpec?
        CardKey.reduce(value: &reducedSpec) { spec }
        CardKey.reduce(value: &reducedSpec) { nil }
        CardKey.reduce(value: &reducedSpec) { nil }
        #expect(reducedSpec == spec)
    }

    /// And the other way round: If the focused row stands **below** empty ones, it still gets
    /// through.
    @Test("A report after empty ones arrives")
    func messageAfterClearingArrives() {
        let spec = CardSpec(header: "kopf", statement: "Deutsch")
        var reducedSpec: CardSpec?
        CardKey.reduce(value: &reducedSpec) { nil }
        CardKey.reduce(value: &reducedSpec) { spec }
        #expect(reducedSpec == spec)
    }

    // MARK: - Every setting reports its card

    /// Sections whose rows **deliberately** report no card — each with its reason.
    ///
    /// **A list with reasons and not a number.** A counter "seven of nineteen" would not say
    /// which twelve are missing and whether on purpose; this way every exception stands there
    /// with its justification, and whoever adds a new one has to write one down.
    static let withoutCard: [String: String] = [
        "AboutSettings.swift":
            "Plain facts (version, device identifier) — the row shows the value, a card beside it would repeat it.",
        "ShelfSources.swift":
            "The tab is a filter over a list and not a setting — it has no scope.",
        "PlaylistSettings.swift":
            "The kind of channel list is a form field at creation and not a setting.",
    ]

    /// Files that **build** the components and do not call them.
    static let blockFiles: Set<String> = [
        "SettingsRows.swift", "RowComponents.swift", "SettingsCard.swift",
    ]

    static let blocks = ["DisclosureRow(", "SwitchRow(", "ChoiceRow(", "ValueRow("]

    static func settingsFiles() throws -> [(name: String, content: String)] {
        try SourceText.files(in: .features, subfolder: "Settings")
            .map { ($0.name, $0.content) }
            .sorted { $0.0 < $1.0 }
    }

    static func tally(_ patterns: String, in text: String) -> Int {
        text.components(separatedBy: patterns).count - 1
    }

    /// **The completion of this line in the roadmap, as a check.** Every place that calls a
    /// settings component gives it a card — otherwise the right column stays empty exactly at
    /// the row where one would have needed it, and nobody notices because empty is an allowed
    /// state.
    @Test("Every building-block call reports a card or is on the list with a reason")
    func eachSettingReportsItsCard() throws {
        for (name, content) in try Self.settingsFiles()
        where !Self.blockFiles.contains(name) && Self.withoutCard[name] == nil {
            let callCount = Self.blocks.reduce(0) { $0 + Self.tally($1, in: content) }
            let cards = Self.tally("card:", in: SourceText.strippingCommentLines(content))
            #expect(
                callCount == cards,
                "\(name): \(callCount) building-block calls, \(cards) cards. Either the row gets a card, or the file is listed with a reason in `ohneKarte`."
            )
        }
    }

    /// **An exception that points to nothing any more is a gap.** If a file is renamed or loses
    /// its last row, its reason would stay and would cover the next file of the same name.
    @Test("Every exception points to a file with building blocks")
    func exceptionsAreLive() throws {
        let files = Dictionary(
            uniqueKeysWithValues: try Self.settingsFiles().map { ($0.name, $0.content) })
        for (name, reason) in Self.withoutCard {
            let content = try #require(files[name], "\(name) is listed in `ohneKarte` but does not exist.")
            let callCount = Self.blocks.reduce(0) { $0 + Self.tally($1, in: content) }
            #expect(
                callCount > 0,
                "\(name) no longer calls a building block — the reason \"\(reason)\" points at nothing."
            )
        }
    }

    // MARK: - The validity

    /// **Four different keys for two cases**, and none of them composed. A key built from the
    /// name counts as unused for `scripts/strings.py`; the next pass clears it away, and then
    /// the card has an empty spot.
    @Test("Every scope has its own keys for label and sentence")
    func validityKey() {
        let all = Validity.allCases.flatMap { [$0.markKey, $0.sentenceKey] }
        #expect(all.count == 4)
        #expect(Set(all).count == 4)
    }

    /// **The badge is not the sentence.** Drawing both from the same key would be convenient
    /// and wrong: On the pill there are two words, next to it a whole sentence.
    @Test("Label and sentence are two keys")
    func labelAndSentenceSeparate() {
        for validity in Validity.allCases {
            #expect(validity.markKey != validity.sentenceKey)
        }
    }

    // MARK: - The preview of the group row

    /// **A hidden group appears outlined and not not at all.** That is the whole statement of
    /// the preview: filled means visible, outlined means hidden. If it showed only the visible
    /// ones, a list with thirty hidden groups would look the same as one without — and the card
    /// would promise that everything can be seen.
    @Test("Hidden groups appear as an unselected pill")
    func hiddenAsOutlines() {
        let pills = LiveSettings.lookahead(
            ["Sport", "Nachrichten", "Kinder"], hidden: ["Nachrichten"])
        #expect(pills.count == 3)
        #expect(pills.first(where: { $0.wording == "Nachrichten" })?.chosen == false)
        #expect(pills.first(where: { $0.wording == "Sport" })?.chosen == true)
    }

    /// **The preview stays a preview.** Eighty pills in a 480 pt wide column would be twenty
    /// rows — the second list this package is built against.
    @Test("The preview shows at most four groups")
    func previewIsLimited() {
        let many = (1...80).map { "Gruppe \($0)" }
        #expect(LiveSettings.lookahead(many, hidden: []).count == LiveSettings.previewCount)
        #expect(LiveSettings.previewCount < 80)
    }

    /// **And it keeps the order of the list.** Pulling only the visible ones forward would mean
    /// showing a different order than the one found on opening.
    @Test("The preview takes the start of the list")
    func previewTakesTheBeginning() {
        let all = ["Sport", "Nachrichten", "Kinder", "Musik", "Doku"]
        let pills = LiveSettings.lookahead(all, hidden: ["Sport"])
        #expect(pills.map(\.wording) == Array(all.prefix(LiveSettings.previewCount)))
    }
}
