import DesignSystem
import Foundation
import SourceProbe
import SwiftUI
import Testing

@testable import Features

/// **Operable without looking** — AP30, 2026-09-11.
///
/// **The rule here is a different one than on the phone, and that is not a shortcut.** There
/// VoiceOver reads everything that is on the screen; here there is no finger that
/// moves over a surface. There is exactly **one** place where something happens: the
/// focus. It follows that **every focusable element says what it is and in which
/// state** — not every element.
///
/// **The inventory therefore runs along the focus targets and not along the
/// files.** What cannot take focus needs nothing; what takes focus and says nothing
/// is the error.
struct ReadAloudAidTests {

    /// The two places where the rule applied first — **and why these two.**
    ///
    /// * The **sidebar**, because it is the only way to everything else. And because
    ///   collapsed it shows **no text**: There the icon alone carries it, and an
    ///   icon is nothing to the screen reader.
    /// * The **player bar**, because the screen is dark there anyway and the
    ///   bar comes and goes.
    static let firstSeen = ["Shell/AppSidebar.swift", "Player/TransportBar.swift"]

    @Test("The sidebar and the player bar label their focus targets")
    func theFirstTwoPlacesAreLabeled() throws {
        for path in Self.firstSeen {
            let content = try SourceText.read(path, in: .features)
            // **What is searched for is the shared building block and no longer the raw call**
            // (AP30, 2026-09-11): Since ``SelectionState`` exists in the DesignSystem, nobody
            // writes `accessibilityLabel` by hand any more — and a check that demands the
            // old spelling would take the new one for a regression.
            #expect(
                content.contains(".info("),
                "\(path) does not label its focus targets")
        }
    }

    /// **The rule now lives in a check and no longer in a resolution.**
    ///
    /// What is searched for is the one form in which a focus target stays mute without it being
    /// noticed when reading: a **bare icon** in the label. `Image(systemName:)`
    /// brings its own name into the screen reader's tree — `checkmark.circle.fill`
    /// instead of "on", `chevron.left` instead of "back two hours". That is a file name
    /// and not information.
    ///
    /// **And it is not noticed when reading because it does not look wrong:** Next to the
    /// icon there is usually a text. That is read out too — but the icon comes first. The
    /// worst case was in the library: There the checkmark keeps its
    /// place via `opacity(0)` so the list does not jitter when toggling, and
    /// `opacity(0)` removes nothing from the screen reader. Every row began with "checkmark" —
    /// the selected one as well as the unselected one.
    ///
    /// An icon **in** a ``Label`` is something else and stays out here:
    /// There it is an accessory to the title, and the screen reader reads the title.
    @Test("No focus target carries its glyph alone")
    func noFocusTargetIsMute() throws {
        var muted: [String] = []

        for file in try SourceText.files(in: .features) {
            let text = file.content
            for button in ButtonSite.all(in: text) where button.carriesFreeSymbol {
                guard !button.providesInfo else { continue }
                let row = text[text.startIndex..<button.start].count(where: { $0 == "\n" }) + 1
                muted.append("\(file.name):\(row)")
            }
        }

        #expect(
            muted.isEmpty,
            """
            Fokusziele mit freiem Zeichen und ohne `.auskunft(…)`:
            \(muted.joined(separator: "\n"))
            """)
    }

    /// **A check that finds nothing must prove that it can find.**
    ///
    /// The template is a real button from this app — the page button of the
    /// programme grid, as it stood until 2026-09-11.
    @Test("The check detects a silent button")
    func theCheckBites() {
        let muted = """
            Button {
                model.blaettere(richtung, jetzt: now)
            } label: {
                Image(systemName: richtung == .zurueck ? "chevron.left" : "chevron.right")
                    .font(.system(size: 22, weight: .semibold))
            }
            .bareFocusableButton()
            .focused($focus, equals: id)
            """
        let locations = ButtonSite.all(in: muted)
        #expect(locations.count == 1)
        #expect(locations.first?.carriesFreeSymbol == true)
        #expect(locations.first?.providesInfo == false)

        // The same with information — and the same once more as a ``Label``, where the
        // icon is an accessory and the title is read.
        let labeled = muted + "\n.info(appKey: \"raster.back\")"
        #expect(ButtonSite.all(in: labeled).first?.providesInfo == true)

        let withLabel = """
            Button {
                Task { await model.toggleWatched(for: item) }
            } label: {
                Label(
                    app: item.isWatched ? "detail.markUnwatched" : "common.markWatched",
                    systemImage: item.isWatched ? "checkmark.circle.fill" : "checkmark.circle"
                )
            }
            """
        #expect(ButtonSite.all(in: withLabel).first?.carriesFreeSymbol == false)
    }

    /// **The sidebar's state information is verifiable by calculation.**
    ///
    /// Three states come together there and do not exclude one another: selected,
    /// expanded, "syncing". The check records that none displaces the others —
    /// and that a row without a state also says nothing.
    @MainActor
    @Test("The row names every state it has — and nothing else")
    func stateReport() {
        func text(_ isActive: Bool, _ character: String?, _ isAligned: Bool) -> String {
            String(
                describing: AppSidebar.stateReport(
                    isActive: isActive, disclosureSymbol: character, isAligned: isAligned))
        }

        // Without a state the information stays empty — not "not selected, collapsed".
        // Whatever is said gets overheard.
        //
        // **Checked against the four keys and not against their prefix**: `strings.py`
        // reads every string of the form `area.name` as a language key, and a
        // bare `a11y.state` in the source would consequently report it as missing. A
        // check that triggers a false alarm in the quality run is not a check.
        let withoutState = text(false, nil, false)
        for key in [
            "a11y.state.selected", "a11y.state.expanded",
            "a11y.state.collapsed", "a11y.state.syncing",
        ] {
            #expect(!withoutState.contains(key))
        }

        #expect(text(true, nil, false).contains("a11y.state.selected"))
        #expect(text(false, "chevron.down", false).contains("a11y.state.expanded"))
        #expect(text(false, "chevron.right", false).contains("a11y.state.collapsed"))
        #expect(text(false, nil, true).contains("a11y.state.syncing"))

        // And all three at once: A selected, expanded row that is currently
        // syncing really exists — "Live" at startup.
        let all = text(true, "chevron.down", true)
        #expect(all.contains("a11y.state.selected"))
        #expect(all.contains("a11y.state.expanded"))
        #expect(all.contains("a11y.state.syncing"))
    }

    /// **A row without a name does not get an invented one.**
    ///
    /// Translated rows carry a key, the names of providers and groups
    /// come raw from the access. If both are missing, that is a finding and no reason for a
    /// placeholder — reading out "Element" would be worse than staying silent.
    @MainActor
    @Test("Without a title the label stays empty instead of invented")
    func noPlaceholders() {
        // `Text` describes itself as `Text(storage: …verbatim(""), …)` — what is checked
        // is therefore the content and not the whole description.
        #expect(
            String(describing: AppSidebar.label(titleKey: nil, title: nil))
                .contains("verbatim(\"\")"))
        #expect(
            String(describing: AppSidebar.label(titleKey: nil, title: "DE| Sport"))
                .contains("DE| Sport"))
    }
}

/// A place in the source where a ``SwiftUI/Button`` stands — **the label
/// separated from the chain behind it.**
///
/// Coarse enough to run across 130 buttons, and precise enough to tell apart the two forms
/// that exist in this app: `Button(action:) { Aufschrift }` and
/// `Button { Tat } label: { Aufschrift }`.
struct ButtonSite {

    let start: String.Index
    let caption: String
    let chain: String

    /// How far behind the label an information is still searched for.
    ///
    /// **The value is measured and not guessed:** At 400 characters two buttons failed,
    /// whose `.info(…)` stands behind a long `focusHighlight` and a paragraph of
    /// reasoning. 900 covers the longest case in this app by a wide margin — and is
    /// short enough that the chain does not reach into the next button.
    static let chainWindow = 900

    static func all(in text: String) -> [ButtonSite] {
        var found: [ButtonSite] = []
        var search = text.startIndex

        while let match = text.range(of: "Button", range: search..<text.endIndex) {
            search = match.upperBound
            var i = match.upperBound

            // `Button(action: …)` — skip the parenthesis if there is one.
            while i < text.endIndex, text[i] == " " { i = text.index(after: i) }
            if i < text.endIndex, text[i] == "(" {
                guard let after = balanced(text, from: i, to: "(", zu: ")") else { continue }
                i = after
            }
            while i < text.endIndex, text[i] == " " || text[i] == "\n" { i = text.index(after: i) }
            guard i < text.endIndex, text[i] == "{" else { continue }
            guard let afterFirst = balanced(text, from: i, to: "{", zu: "}") else { continue }
            let first = String(text[i..<afterFirst])

            // `Button { Tat } label: { Aufschrift }` — then the second block is the
            // label, not the first.
            var j = afterFirst
            var caption = first
            let rest = text[afterFirst...].prefix(40)
            if let label = rest.range(of: "label:") {
                var k = label.upperBound
                while k < text.endIndex, text[k] == " " || text[k] == "\n" {
                    k = text.index(after: k)
                }
                if k < text.endIndex, text[k] == "{",
                    let afterSecond = balanced(text, from: k, to: "{", zu: "}")
                {
                    caption = String(text[k..<afterSecond])
                    j = afterSecond
                }
            }

            let end = text.index(j, offsetBy: chainWindow, limitedBy: text.endIndex)
            found.append(
                ButtonSite(
                    start: match.lowerBound,
                    caption: caption,
                    chain: String(text[j..<(end ?? text.endIndex)])))
        }
        return found
    }

    /// An icon that stands **next to** the text instead of inside a ``SwiftUI/Label``.
    var carriesFreeSymbol: Bool {
        let withoutLabel = Self.withoutLabel(caption)
        return withoutLabel.contains("systemName") || withoutLabel.contains("Glyph.")
    }

    var providesInfo: Bool {
        chain.contains(".info(") || chain.contains(".accessibilityLabel")
            || chain.contains("children: .ignore")
    }

    /// Strikes out every ``SwiftUI/Label`` together with its icon.
    ///
    /// Both forms: `Label(app:systemImage:)` and `Label { Title } icon: { Zeichen }`.
    /// There the icon is an accessory — the screen reader reads the title and does not
    /// mention the icon's name at all.
    static func withoutLabel(_ text: String) -> String {
        var rest = text
        while let start = rest.range(of: "Label") {
            var i = start.upperBound
            while i < rest.endIndex, rest[i] == " " || rest[i] == "\n" { i = rest.index(after: i) }
            guard i < rest.endIndex else { break }

            var end: String.Index?
            if rest[i] == "(" {
                end = balanced(rest, from: i, to: "(", zu: ")")
            } else if rest[i] == "{", let byTitle = balanced(rest, from: i, to: "{", zu: "}") {
                var k = byTitle
                if let icon = rest[k...].prefix(20).range(of: "icon:") {
                    k = icon.upperBound
                    while k < rest.endIndex, rest[k] == " " || rest[k] == "\n" {
                        k = rest.index(after: k)
                    }
                    if k < rest.endIndex, rest[k] == "{" {
                        end = balanced(rest, from: k, to: "{", zu: "}")
                    }
                }
                if end == nil { end = byTitle }
            }
            guard let end else { break }
            rest.replaceSubrange(start.lowerBound..<end, with: "")
        }
        return rest
    }
}

/// The end of a bracketed block that begins at `from`.
private func balanced(
    _ text: String, from start: String.Index, to: Character, zu: Character
) -> String.Index? {
    var depth = 0
    var i = start
    while i < text.endIndex {
        if text[i] == to {
            depth += 1
        } else if text[i] == zu {
            depth -= 1
            if depth == 0 { return text.index(after: i) }
        }
        i = text.index(after: i)
    }
    return nil
}
