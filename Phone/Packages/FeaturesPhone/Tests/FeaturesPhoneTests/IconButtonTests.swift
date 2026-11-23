import Foundation
import SourceProbe
import Testing

/// **A button that carries only a symbol says what it does** — finding B7 of the check of
/// 2026-09-27.
///
/// The setup's back button carried `chevron.left` and nothing else. VoiceOver then reads
/// the name of the symbol, a file name and not information.
///
/// **Narrower than the rule on the TV** (`ReadAloudAidTests`): There every focus target
/// takes the focus, and a symbol next to a text is read before the text. On the phone
/// VoiceOver reads the row's text along; what is searched for here is only the button
/// whose entire label is **one** `Image(systemName:)`.
@Suite("Buttons with a bare symbol")
struct IconButtonTests {

    static let locations: [CodeLocation] = [.featuresPhone, .designSystemPhone, .phoneApp]

    @Test("No button carries just a symbol without a label")
    func noSilentButton() throws {
        var muted: [String] = []
        var counted = 0
        for location in Self.locations {
            for file in try SourceText.files(in: location) {
                for button in Self.buttons(in: file.content) {
                    counted += 1
                    guard button.iconOnly, !button.labeled else { continue }
                    muted.append("\(file.path):\(button.row)")
                }
            }
        }
        #expect(counted > 50, "the search no longer finds buttons")
        #expect(muted.isEmpty, "Button with a bare symbol and no accessibilityLabel: \(muted)")
    }

    @Test("The search recognizes the mute button and leaves the labeled one alone")
    func searchTakesEffect() {
        let muted = """
            Button {
                model.back()
            } label: {
                Image(systemName: Glyph.back.name)
                    .foregroundStyle(ColorRole.textMatt.color)
            }
            .frame(width: 44, height: 44)
            """
        #expect(Self.buttons(in: muted).map(\.iconOnly) == [true])
        #expect(Self.buttons(in: muted).map(\.labeled) == [false])
        let labeled = muted + "\n.accessibilityLabel(Text(app: \"common.back\"))"
        #expect(Self.buttons(in: labeled).map(\.labeled) == [true])
        let withText = """
            Button(action: add) {
                row("accounts.add", symbol: Glyph.signIn.name)
            }
            """
        #expect(Self.buttons(in: withText).map(\.iconOnly) == [false])
    }

    // MARK: - Suche

    struct ButtonProbe {
        let row: Int
        let iconOnly: Bool
        let labeled: Bool
    }

    /// How far behind the label a caption is searched for — the same value as on the TV.
    static let chainWindow = 900

    static func buttons(in text: String) -> [ButtonProbe] {
        let character = Array(text)
        var found: [ButtonProbe] = []
        var search = text.startIndex
        while let match = text.range(of: "Button", range: search..<text.endIndex) {
            search = match.upperBound
            var i = text.distance(from: text.startIndex, to: match.upperBound)
            while i < character.count, character[i] == " " { i += 1 }
            if i < character.count, character[i] == "(" {
                guard let closeIndex = balanced(character, from: i, to: "(", closing: ")") else {
                    continue
                }
                i = closeIndex
            }
            while i < character.count, character[i] == " " || character[i] == "\n" { i += 1 }
            guard i < character.count, character[i] == "{",
                let afterFirst = balanced(character, from: i, to: "{", closing: "}")
            else { continue }
            var caption = String(character[i..<afterFirst])
            var end = afterFirst
            let rest = String(character[afterFirst..<min(afterFirst + 40, character.count)])
            if let label = rest.range(of: "label:") {
                var k = afterFirst + rest.distance(from: rest.startIndex, to: label.upperBound)
                while k < character.count, character[k] == " " || character[k] == "\n" { k += 1 }
                if k < character.count, character[k] == "{",
                    let afterSecond = balanced(character, from: k, to: "{", closing: "}")
                {
                    caption = String(character[k..<afterSecond])
                    end = afterSecond
                }
            }
            let chain = String(character[end..<min(end + chainWindow, character.count)])
            let row = text[text.startIndex..<match.lowerBound].count(where: { $0 == "\n" }) + 1
            found.append(
                ButtonProbe(
                    row: row, iconOnly: iconOnly(caption),
                    labeled: chain.contains(".accessibilityLabel") || chain.contains(".info(")
                        || chain.contains("children: .ignore")))
        }
        return found
    }

    /// The label is an `Image(systemName:)` with its modifiers and nothing else.
    static func iconOnly(_ caption: String) -> Bool {
        let rows = caption.dropFirst().dropLast()
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix(".") && !$0.hasPrefix("//") && !$0.hasPrefix(")") }
        guard let first = rows.first, first.hasPrefix("Image(systemName") else { return false }
        return rows.dropFirst().allSatisfy { !($0.first?.isLetter ?? false) }
    }

    static func balanced(
        _ character: [Character], from start: Int, to: Character, closing: Character
    ) -> Int? {
        var depth = 0
        var i = start
        while i < character.count {
            if character[i] == to { depth += 1 }
            if character[i] == closing {
                depth -= 1
                if depth == 0 { return i + 1 }
            }
            i += 1
        }
        return nil
    }
}
