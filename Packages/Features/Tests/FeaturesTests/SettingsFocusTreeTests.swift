import Foundation
import SourceProbe
import Testing

@testable import Features

/// **What silently damages the focus tree of the settings** — AP22, 2026-09-11.
///
/// **Why these are checks on the source and not on a type.** Both findings only take effect
/// on the device, in focus, and both are invisible: No call throws, no state is wrong,
/// there is merely a target missing in the tree. A check that builds the same view would see
/// none of it — tvOS assigns the focus, not SwiftUI. What remains verifiable is the
/// **rule**: These two patterns do not occur in the settings, except at the places named
/// here and justified.
///
/// The approach is decided in the project — ``TransportSecurityRuleTests`` has been
/// reading the real `project.yml` instead of a rebuilt one since 2026-08-22, for the same
/// reason.
enum SettingsSources {

    /// The folder with the settings sections — and the parental controls, which are one of
    /// them but live with the accounts.
    static func files() throws -> [(name: String, content: String)] {
        var found: [(String, String)] = []
        for folder in ["Settings", "Accounts"] {
            for file in try SourceText.files(in: .features, subfolder: folder) {
                found.append((file.name, file.content))
            }
        }
        #expect(found.count >= 10, "the settings sections were not found")
        return found.sorted { $0.0 < $1.0 }
    }

    /// The views that lie over a section instead of in it — **read off, not enumerated.**
    ///
    /// **A full-screen sheet is not a section** (sharpened on 2026-09-11, AP29). The rule below
    /// applies to what ``SettingsView`` puts **in** its scroll area; a `fullScreenCover`
    /// replaces the screen and shares no axis with it — it needs its own area, otherwise its
    /// content below the edge would be unreachable.
    ///
    /// **Read off and not entered in an exception list**, because an exception list is the
    /// beginning of the second way of building: What is searched for is what the sections show
    /// as a sheet themselves. Whoever adds a sheet tomorrow enters it nowhere — and whoever puts
    /// a scroll area into a real section still gets caught.
    static func sheets(in files: [(name: String, content: String)]) -> Set<String> {
        var found: Set<String> = []
        for (_, content) in files {
            let rows = content.split(separator: "\n", omittingEmptySubsequences: false)
            for (index, row) in rows.enumerated() where row.contains("fullScreenCover") {
                // The type name appears in one of the next lines, as a call: `Sheet(`.
                for followingRow in rows.dropFirst(index).prefix(6) {
                    let text = followingRow.trimmingCharacters(in: .whitespaces)
                    guard !text.hasPrefix("//"), let bracket = text.firstIndex(of: "(")
                    else { continue }
                    let name = String(text[text.startIndex..<bracket])
                    // **A plain name, capitalized** — `Color.clear.fullScreenCover` and
                    // `ColorRole.reason.color.ignoresSafeArea` appear in the same six lines and are not
                    // sheets. The comparison with the files that actually exist catches the rest.
                    guard name.first?.isUppercase == true, !name.contains(".") else { continue }
                    found.insert(name)
                    break
                }
            }
        }
        // **Only what exists.** A name with no file is a misreading by the scan — and a check that
        // excludes false hits instead of reporting them will eventually exclude real ones too.
        return Set(
            files.filter { file in
                found.contains { file.content.contains("struct \($0): View") }
            }.map(\.name))
    }

    /// Lines with a pattern — **without comment lines.**
    ///
    /// In the justifications the rejected pattern is explicitly still there, so that readers
    /// know what once stood here. A check that counts the comment too would break on exactly
    /// the sentence that explains it.
    static func match(_ patterns: String, in content: String) -> [String] {
        content.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") && !$0.hasPrefix("///") && $0.contains(patterns) }
    }
}

/// **On tvOS `.disabled` removes the focus target, not just the effect.**
///
/// On the phone a disabled button turns pale and stays put. On the TV it drops out of the
/// focus tree: The focus jumps to the geometrically nearest target, and after the switch
/// that lies somewhere. **The pattern is therefore: stay focusable, look grayed out,
/// discard the press in the body** — `OtherSettings.shelfRow` has promised it in a comment
/// all along.
///
/// **Before 2026-09-11 this check was red, in four places.** The worst was
/// `OtherSettings:341`: `icons.isSwitching` switched off **all tiles of the grid at once**
/// while the app icon was being switched.
@Test("In Settings no button takes away its focus target")
func noDisabledInSettings() throws {
    // **No exceptions any more** (AP22 completed on 2026-09-11). There were two here:
    // `measuring` and `sending` in the diagnostics — short-lived states in which the focus
    // drops out all the same. They are now corrected, and the count is therefore zero.
    //
    // **An exception list that becomes empty is the only good outcome for one.** As long as it
    // carries entries, it is an agreement for a limited time; empty, it is a rule.
    let known: [String: Int] = [:]

    for (name, content) in try SettingsSources.files() {
        let match = SettingsSources.match(".disabled(", in: content)
        #expect(
            match.count == (known[name] ?? 0),
            """
            \(name): \(match.count) × .disabled — expected \(known[name] ?? 0).
            On tvOS a disabled button is not a faded button but none at all: \
            it drops out of the focus tree, and focus ends up somewhere afterwards. \
            Instead keep it focusable, draw it greyed out and discard the press in the \
            button body (`guard enabled else { return }`).
            \(match.joined(separator: "\n"))
            """
        )
    }
}

/// **Two nested scroll areas share the scrolling — and one loses.**
///
/// ``SettingsView`` wraps every section in a `ScrollView`. A second, unbounded one inside
/// takes the scrolling after the focus, the outer one no longer moves, and what lies below
/// the edge stays there. **Before 2026-09-11 this check was red in two places** — of all
/// things at "Portale" and "Kindersicherung"; the eight other sections only deliver a
/// `VStack`.
@Test("Only the bounded log list scrolls in a second surface")
func noNestedScrollArea() throws {
    // **The only deliberately nested one**, and it is the proof that it works: It is limited
    // to 620 pt, in a `focusSection()` of its own, and its justification stands in detail
    // beside it (F-041, 2026-09-04).
    //
    // **`SettingsView` has carried two since 2026-09-25** (product decision 1): Beside the
    // content area, the section list now scrolls too. The two stand **side by side** and not
    // inside each other — neither takes the other's scrolling.
    let known = ["DiagnosticsSettings.swift": 1, "SettingsView.swift": 2]

    let files = try SettingsSources.files()
    let sheets = SettingsSources.sheets(in: files)
    // The rule must find the sheets, otherwise at the next rework it silently checks nothing
    // any more — the same lesson as with every check that finds nothing.
    #expect(!sheets.isEmpty, "no full-screen sheet recognized — the reading does not take hold")

    for (name, content) in files where !sheets.contains(name) {
        // **What is counted are vertical areas — and only those** (sharpened on 2026-09-11, AP26).
        // The finding from AP22 was a second **unbounded vertical** scroll area: It takes the
        // scrolling after the focus, and the outer one no longer moves. A **horizontal** one does
        // not — it shares no axis with the outer one at all.
        //
        // The first draft counted every occurrence of "ScrollView" and thereby also reported
        // `ScrollViewReader` and `ScrollViewProxy` — that is, this package's jump-marker rework,
        // which builds no second area at all. **A check that reports false hits gets switched
        // off.**
        let match =
            SettingsSources.match("ScrollView {", in: content)
            + SettingsSources.match("ScrollView(.vertical)", in: content)
        #expect(
            match.count == (known[name] ?? 0),
            """
            \(name): \(match.count) × ScrollView — expected \(known[name] ?? 0).
            A settings section already sits in the scroll view of \
            SettingsView. A second, unbounded one inside takes over scrolling, \
            and the content below the edge becomes unreachable. A `VStack` is enough; \
            a bounded area needs a height and a reason.
            \(match.joined(separator: "\n"))
            """
        )
    }
}

/// **Every section names its first target — otherwise the right press fizzles.**
///
/// Without the report, no catcher at the content edge arises at all
/// (``SettingsView/showsContentCatcher(focus:firstEntry:)``), and tvOS assigns the focus by
/// geometry. **Before 2026-09-11 this check was red in two places**, and of all things at
/// the two sections behind the door: "Portale" and "Kindersicherung".
///
/// Since AP23 more hangs on it than the right press: The **selection press** on an entry of
/// the section list jumps into the content, but only if the section reports a first target
/// (`SettingsView.sectionButton`). A section without a report would have a button with no
/// effect.
@Test("Every settings section reports its first target")
func eachSectionReportsItsFirstTarget() throws {
    // The section → the type that draws it (``SettingsView/content``).
    let sections: [SettingsSection: String] = [
        .playlists: "PlaylistSettings", .portals: "PortalSettings", .live: "LiveSettings",
        .playback: "PlaybackSettings", .ratings: "RatingsSettings",
        .appearance: "AppearanceSettings", .storage: "StorageSettings",
        .childLock: "ParentalControlsView", .account: "AccountSettings",
        .about: "AboutSettings", .language: "LanguageSettings",
        .profiles: "ProfileSettings",
        .devices: "OtherDevicesSettings",
    ]

    // **The one exception, and it is older and justified.** The diagnostics are not reported
    // through a preference but intercepted by name: Their log list is so long that tvOS would
    // geometrically hit some row, and the correction afterwards was visible as a jump
    // (F-041, 2026-09-04). ``showsContentCatcher`` therefore lists it as a second condition.
    #expect(
        SettingsView.showsContentCatcher(
            focus: "section-" + SettingsSection.diagnostics.id, firstEntry: nil),
        "Diagnostics has lost its own path")
    #expect(sections.count == SettingsSection.allCases.count - 1)

    let files = try SettingsSources.files()
    for (area, contentType) in sections {
        guard let file = files.first(where: { $0.content.contains("struct \(contentType): View") })
        else {
            Issue.record("\(contentType) for section \(area.id) not found")
            continue
        }
        // The type and everything that follows it in the file — `OtherSettings.swift` carries
        // four of these sections one after another.
        let startIndex = file.content.range(of: "struct \(contentType): View")!.lowerBound
        let rest = file.content[startIndex...]
        let endIndex =
            rest.dropFirst().range(of: "\nstruct ")?.lowerBound ?? rest.endIndex
        let bodyContent = rest[..<endIndex]

        #expect(
            bodyContent.contains("SettingsFirstEntryKey"),
            """
            \(contentType) (\(area.id)) reports no first target — the right press then assigns \
            by geometry, and the select press has no effect.
            """)
        #expect(
            bodyContent.contains("settingsEntryRequest"),
            "\(contentType) (\(area.id)) does not accept the jump request")
    }
}
