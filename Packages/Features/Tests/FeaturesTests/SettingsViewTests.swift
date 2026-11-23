import Core
import CoreGraphics
import DesignSystem
import Foundation
import SourceProbe
import SwiftUI
import Testing

@testable import Features

/// Verifies that the settings area list carries its texts.
///
/// This suite exists because of a bug that stood on every settings screen for
/// weeks without being noticed: "Einstellungen" wrapped in the
/// 380-point column without a hyphen in the middle of the word — "Einstellung/en", in the
/// largest type on the page. SwiftUI does not warn about this, and whoever looks only at the short
/// titles "Settings" and "Ayarlar" takes the column for wide enough.
@Suite("Settings section list")
@MainActor
struct SettingsViewTests {

    @Test("The heading fits on one line in its column")
    func titleFitsOnOneLine() {
        // Re-measured with CoreText: "Einstellungen" is the widest of the three
        // translations and needs 301 points at 48 pt bold — at 57 pt it would be
        // 356, and that wrapped. Whoever makes the column narrower or raises the
        // heading again sees it here instead of on the TV.
        let longestTitle: CGFloat = 301

        #expect(
            SettingsView.titleWidth >= longestTitle,
            """
            only \(Int(SettingsView.titleWidth)) points for the heading,
            “Einstellungen” needs \(Int(longestTitle))
            """
        )
        #expect(
            SettingsView.titleSize <= TypeLevel.section.points,
            "at \(Int(SettingsView.titleSize)) pt “Einstellungen” wraps again"
        )
    }

    @Test("The section entries keep the navigation rule: at least body")
    func sectionEntriesAreReadable() {
        // "A navigation entry must be read" — with this rule the
        // sidebar was raised to 29 pt. This list can appear on screen together with it;
        // two sizes for the same purpose would be a visible contradiction,
        // and 27 pt is below the legibility limit of the project's own tokens.
        #expect(SettingsView.entrySize >= TypeLevel.text.points)
    }

    @Test("The longest section entry is not truncated")
    func longestSectionEntryFits() {
        // The entries carry `lineLimit(1)`; too little space means not a
        // wrap but an ellipsis. Re-measured with CoreText at 29 pt
        // semibold (the weight of the selected entry): "Değerlendirmeler" needs
        // 229 points — German is not the worst case, the widest
        // German entry "Bewertungen" is only 177.
        let longestEntry: CGFloat = 229

        #expect(
            SettingsView.entryTextWidth >= longestEntry,
            """
            only \(Int(SettingsView.entryTextWidth)) points for the label,
            the longest entry needs \(Int(longestEntry))
            """
        )
    }

    // MARK: - The section list scrolls

    /// **Until 2026-09-25 this said "All areas fit on the screen without
    /// scrolling"** — a calculation over eleven entries and three gaps against 1080 pt.
    /// Owner decision 1 repeals it: fourteen areas, **visible
    /// group headers, the list scrolls.** What the calculation protected — every entry is
    /// reachable —, focus protects now. What is tested is therefore the connection on which
    /// that hangs: that the list sits in a scroll area and the headers scroll along.
    @Test("The section list scrolls, and the headers scroll with it")
    func theListScrolls() throws {
        let source = try SourceText.read("SettingsView.swift", in: .features)
        let list = try #require(
            source.range(of: "private var sectionList: some View {").map {
                String(source[$0.lowerBound...].prefix(2400))
            })

        #expect(
            list.contains("ScrollView {"),
            "The section list is in no scroll view — the fourteenth section would lie below the edge.")
        #expect(
            list.contains("role.scrollTo(Self.groupHeaderID("),
            "Focus does not scroll the group header along — the first section would stand without its header."
        )
        #expect(
            source.contains(".id(Self.groupHeaderID(group))"),
            "The group header carries no identifier — `scrollTo` would not find it and scroll into nothing.")
    }

    /// **The first area of a group brings its header into view** — and only it.
    ///
    /// tvOS scrolls the focused entry into view, but only it. Whoever jumps from the end via the wraparound
    /// to "Media server" would see the entry without "Sources" above it.
    @Test("The first section of each group scrolls its header along")
    func firstSectionTakesHeaderAlong() {
        for group in SettingsSection.Group.allCases {
            let sections = group.sections
            #expect(!sections.isEmpty, "\(group) has no section")
            guard let first = sections.first else { continue }
            #expect(
                SettingsView.groupHeaderInView(forItem: first) == group,
                "\(first.rawValue) starts \(group) and does not take the header along")
            for otherSection in sections.dropFirst() {
                #expect(
                    SettingsView.groupHeaderInView(forItem: otherSection) == nil,
                    "\(otherSection.rawValue) scrolls a header into view that sits far above")
            }
        }
    }

    /// **The grouping of drawing `EB`, as decided on 2026-09-25.**
    /// Since AP59 N7 (2026-09-30) three: Language under Playback, "About" under Device.
    @Test("Three groups in the decided order")
    func outlineByDecision() {
        #expect(SettingsSection.Group.sources.sections == [.account, .playlists, .portals, .ratings])
        #expect(
            SettingsSection.Group.watching.sections
                == [.appearance, .playback, .live, .language])
        #expect(
            SettingsSection.Group.device.sections
                == [.profiles, .childLock, .devices, .storage, .diagnostics, .about])
        #expect(SettingsSection.Group.allCases.count == 3)
    }

    /// **The three columns must fit side by side on the screen** (AP46, 2026-09-24).
    ///
    /// Since the ``SettingsCard`` stands on the right, the width is a calculation with
    /// six terms and no longer "the rest". **And whatever sticks out on the right is, on
    /// a TV, not scrollable but gone** — unlike a page that is too long, which
    /// can at least be scrolled down. The same kind of test as for the list height
    /// next to it, only in the other direction.
    ///
    /// **The main bar belongs in the calculation** (on-device test 2026-09-27, T5/T10): Until
    /// then the sum counted only the settings themselves and came to 1916 of 1920.
    /// To the left, though, there is always the collapsed ``AppSidebar`` — together
    /// 2032 points, and the centered row lost the bar on the left and the card on the right.
    @Test("Section list, rows and card fit next to the collapsed sidebar")
    func theThreeColumnsFit() {
        let needed =
            AppSidebar.collapsedWidth
            + 1
            + SettingsView.sectionListWidth
            + SettingsView.contentInset
            + SettingsView.contentWidth
            + SettingsView.contentInset
            + SettingsView.cardWidth
            + SettingsView.contentInset
        #expect(
            needed <= SettingsView.screenWidth,
            """
            Sidebar and three columns need \(Int(needed)) of \
            \(Int(SettingsView.screenWidth)) points. The card on the right falls out of \
            the picture — either it gets narrower, or the row column gives up width.
            """
        )
    }

    /// **Four groups, four headers.**
    ///
    /// The headers arise from group membership and not from a second list
    /// — whoever enumerated them would forget them at the next area. **Since 2026-09-25 also
    /// before the first entry**: There until then stood no gap, but a header did.
    @Test("Every group starts with a header")
    func headersFollowTheGroups() {
        #expect(
            SettingsSection.allCases.first?.startsGroup == true, "a header precedes the first entry")

        let withHead = SettingsSection.allCases.filter(\.startsGroup)
        #expect(
            withHead.count == SettingsSection.Group.allCases.count,
            "\(withHead.count) headers for \(SettingsSection.Group.allCases.count) groups")

        // And the groups stand in one piece: no area of a group stands behind an
        // area of another that was already complete.
        var seenGroups: [SettingsSection.Group] = []
        for area in SettingsSection.allCases where seenGroups.last != area.group {
            #expect(
                !seenGroups.contains(area.group),
                "\(area.group) starts a second time — the group is torn apart")
            seenGroups.append(area.group)
        }
    }

    // MARK: - Entering diagnostics

    /// **Entry begins at the top** (user request 2026-08-15): when entering the content,
    /// tvOS assigns focus by geometry — with a long log list,
    /// some row in the middle.
    @Test("From the section list into diagnostics lands on the switch")
    func diagnosticsEntryLandsOnTop() {
        let corrected = SettingsView.correctedDiagnosticsEntry(
            from: "section-diagnostics",
            to: "log-5501390A-34F2-48CD-A674-67F2D70127CC"
        )
        #expect(corrected == SettingsView.diagnosticsTopID)

        #expect(
            SettingsView.correctedDiagnosticsEntry(
                from: "section-diagnostics", to: "sendLog"
            ) == SettingsView.diagnosticsTopID)
    }

    @Test("Whoever already lands on top or wanders in the content is left alone")
    func diagnosticsEntryLeavesNavigationAlone() {
        // Entry already hits the topmost entry — nothing to do.
        #expect(
            SettingsView.correctedDiagnosticsEntry(
                from: "section-diagnostics", to: "debugMode"
            ) == nil)
        // Movement within the content — otherwise one could never get away from the top.
        #expect(
            SettingsView.correctedDiagnosticsEntry(from: "debugMode", to: "engine-native") == nil)
        #expect(SettingsView.correctedDiagnosticsEntry(from: "measure", to: "sendLog") == nil)
        // Other areas do not know this correction.
        #expect(
            SettingsView.correctedDiagnosticsEntry(from: "section-playback", to: "sendLog") == nil)
        // And without a target there is nothing to correct.
        #expect(
            SettingsView.correctedDiagnosticsEntry(from: "section-diagnostics", to: nil) == nil)
    }
}

/// The report truncation — the server accepts client logs only up to about one
/// megabyte (on-device finding 2026-08-16: "Cannot send" was in truth
/// a report that was too large).
@Suite("Diagnostics · report truncation")
/// On the main actor, because the rule under test lives there (AP15, 2026-09-02):
/// the warning gate turns "nonisolated calls MainActor" into a
/// failure — and in substance it always was one.
@MainActor
struct ReportTailTests {

    @Test("What fits stays untouched")
    func smallTextsStayWhole() {
        #expect(DiagnosticsSettings.tail(of: "eins\nzwei", maxBytes: 100) == "eins\nzwei")
    }

    @Test("Truncation happens at the front, on line boundaries, with an honest marker")
    func trimsFromTheFront() {
        let text = (1...100).map { "Zeile \($0)" }.joined(separator: "\n")
        let cut = DiagnosticsSettings.tail(of: text, maxBytes: 200)

        #expect(cut.hasPrefix("… (cut at the front"))
        #expect(cut.hasSuffix("Zeile 100"), "the newest stays")
        #expect(!cut.contains("Zeile 1\n"), "the oldest drops")
        #expect(cut.utf8.count < 250)
    }
}

/// The focus guidance of Settings — the findings of 2026-09-04.
@Suite("Settings · jumps without input")
struct SettingsFocusRuleTests {
    private let now = Date(timeIntervalSince1970: 1000)

    @Test("From the list into the content is the case to check")
    func entryIsRecognised() {
        #expect(SettingsView.isContentEntry(previous: "section-diagnostics", current: "sendLog"))
        #expect(SettingsView.isContentEntry(previous: "section-diagnostics", current: "log-1"))
        #expect(!SettingsView.isContentEntry(previous: "section-storage", current: "section-diagnostics"))
        #expect(!SettingsView.isContentEntry(previous: "section-live", current: "list-return"))
        #expect(!SettingsView.isContentEntry(previous: "debugMode", current: "measure"))
        #expect(!SettingsView.isContentEntry(previous: nil, current: "list-entry"))
    }

    @Test("A right press shortly before or after entering confirms it")
    func rightPressConfirms() {
        // The command comes after the focus (F-043: 50–70 ms later) …
        #expect(SettingsView.isConfirmedEntry(lastMove: (.right, now.addingTimeInterval(0.07)), since: now))
        // … or, depending on the order, just before it.
        #expect(SettingsView.isConfirmedEntry(lastMove: (.right, now.addingTimeInterval(-0.1)), since: now))
        // An old right press does not count, a downward press never.
        #expect(!SettingsView.isConfirmedEntry(lastMove: (.right, now.addingTimeInterval(-5)), since: now))
        #expect(!SettingsView.isConfirmedEntry(lastMove: (.down, now.addingTimeInterval(0.05)), since: now))
        #expect(!SettingsView.isConfirmedEntry(lastMove: nil, since: now))
    }
}

/// The holder for Picture in Picture — which target is the same (AP8).
@Suite("Picture in Picture · holder")
struct PictureInPictureKeeperTests {
    @Test("The same target means the same address, not the same value")
    func sameTargetByAddress() {
        let decision = PlaybackDecision(engine: .native, delivery: .remuxInApp, reason: .remuxedInApp)
        let a = PlaybackTarget(
            itemID: nil, title: "TELVE 1", url: URL(string: "http://p/live/1.ts")!, decision: decision)
        let b = PlaybackTarget(
            itemID: nil, title: "TELVE 1", url: URL(string: "http://p/live/1.ts")!, decision: decision,
            startAt: 12)
        let c = PlaybackTarget(
            itemID: nil, title: "TELVE 2", url: URL(string: "http://p/live/2.ts")!, decision: decision)
        #expect(PictureInPictureKeeper.matches(a, b))
        #expect(!PictureInPictureKeeper.matches(a, c))
    }
}

/// Who receives the list with a start marker.
@Suite("Continue Watching · who gets the start marker")
struct StartRelayRuleTests {
    @Test("A recording over HLS from a position — otherwise not")
    func onlyResumedHLSRecordings() {
        let hls = PlaybackDecision(engine: .native, delivery: .hls, reason: .containerNotNativelySupported)
        let url = URL(string: "http://s/Videos/x/main.m3u8")!
        #expect(
            PlayerModel.wantsStartRelay(
                PlaybackTarget(itemID: "x", title: "F", url: url, decision: hls, startAt: 900)))
        #expect(
            !PlayerModel.wantsStartRelay(
                PlaybackTarget(itemID: "x", title: "F", url: url, decision: hls, startAt: 0)))
        #expect(
            !PlayerModel.wantsStartRelay(
                PlaybackTarget(itemID: "x", title: "F", url: url, decision: hls, startAt: 900, kind: .live)))
        let direct = PlaybackDecision(engine: .native, delivery: .directPlay, reason: .nativeContainer)
        #expect(
            !PlayerModel.wantsStartRelay(
                PlaybackTarget(itemID: "x", title: "F", url: url, decision: direct, startAt: 900)))
    }
}
