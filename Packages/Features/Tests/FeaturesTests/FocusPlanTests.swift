import Foundation
import ParentalControls
import SourceProbe
import Testing

@testable import Features

/// **The done condition of AP46 as a guard** — "the focus targets per section on the first
/// level under 15" (found 2026-09-24, built 2026-09-25).
///
/// **The number cannot be counted statically because it depends on the data:** A `ForEach`
/// over `SubtitleMode.allCases` is bounded, one over a household's channel lists is not. The
/// roadmap left open whether a guard keeps the data-dependent places **as a list with
/// justifications** or whether the number remains a matter for the device. Here is the list:
/// It is more expensive, but it breaks when someone builds in a focus target and nobody
/// takes responsibility for it.
///
/// **The connection the guard hangs on is the identifier.** Every focus target of a section
/// carries one (`identifier: "audio"`, `id: "up-" + name`, `equals: "signout"`), and every one
/// of them must be in the ``FocusPlan`` of its section — with its count. A new target without
/// an item is red; an item whose identifier no longer exists is too. An identifier that is
/// built further with `+` sits in a loop or a helper function per entry and must therefore
/// never be counted as ``FocusPlan/Quantity/one``.
enum FocusPlan {

    /// How many focus targets an item provides on the first level.
    enum Quantity {
        case one
        /// An enumeration — the number comes from the type itself, not from the plan.
        case perCase(Int, reason: String)
        /// A household's data — the number is the usual one, and the reason says where from.
        case data(typical: Int, reason: String)
        /// Reading material **at the end** of a section, in an area of its own: focusable so that it
        /// scrolls, without effect, and no path to a setting leads through it. It costs one press in
        /// and none to get past it.
        case readingText(reason: String)
        /// Visible only behind a row (mode, form, expanded request).
        case secondLevel(reason: String)

        var number: Int {
            switch self {
            case .one, .readingText: 1
            case .perCase(let n, _): n
            case .data(let n, _): n
            case .secondLevel: 0
            }
        }

        var isSingle: Bool { if case .one = self { true } else { false } }
    }

    struct LineItem {
        let identifier: String
        let count: Quantity
        init(_ identifier: String, _ count: Quantity = .one) {
            self.identifier = identifier
            self.count = count
        }
    }

    struct Area {
        /// The views whose identifiers belong to the section — the first draws it.
        let views: [String]
        /// Embedded views with their own focus that only stand on the second level.
        var next: [String: String] = [:]
        let items: [LineItem]
    }

    static let form = "appears only after \"Add\" and replaces the button"

    static let plan: [SettingsSection: Area] = [
        .account: Area(
            views: ["AccountSettings"],
            items: [
                LineItem(
                    "cert-",
                    .data(
                        typical: 2,
                        reason:
                            "one revoke per trusted self-issued certificate — a household has one, rarely two servers"
                    )),
                LineItem("signout"),
                // Only without access, then instead of all the others (on-device test 2026-09-27).
                LineItem("addServer"),
            ]),
        .playlists: Area(
            views: ["PlaylistSettings"],
            items: [
                LineItem(
                    "refresh-", .data(typical: 2, reason: "per channel list; a household has one to two")),
                LineItem("toggle-", .data(typical: 2, reason: "per channel list")),
                LineItem("delete-", .data(typical: 2, reason: "per channel list")),
                LineItem("add"),
                LineItem("kind-", .secondLevel(reason: form)),
                LineItem("name", .secondLevel(reason: form)),
                LineItem("address", .secondLevel(reason: form)),
                LineItem("user", .secondLevel(reason: form)),
                LineItem("pass", .secondLevel(reason: form)),
                LineItem("epg", .secondLevel(reason: form)),
                LineItem("save", .secondLevel(reason: form)),
                LineItem("cancel", .secondLevel(reason: form)),
            ]),
        .portals: Area(
            views: ["PortalSettings", "ApprovalList"],
            items: [
                LineItem("portals-enabled"), LineItem("bridge"), LineItem("save-bridge"),
                LineItem("find-bridge"),
                // The three states exclude each other; all are counted nonetheless.
                LineItem("pairing"), LineItem("redeem"), LineItem("join-request"), LineItem("join-cancel"),
                LineItem(
                    "person-",
                    .data(typical: 2, reason: "the household's people, only as long as none is chosen")),
                LineItem("signout"),
                LineItem("join-", .data(typical: 1, reason: "per open join request; usually none")),
                LineItem("join-role-", .secondLevel(reason: "only after a request is chosen")),
                LineItem("join-console", .secondLevel(reason: "only after a role that may have the console")),
                LineItem("join-pin", .secondLevel(reason: "only after a request is chosen")),
                LineItem("join-own-pin", .secondLevel(reason: "only after a request is chosen")),
                LineItem("join-name", .secondLevel(reason: "only after a request is chosen")),
                LineItem("join-approve", .secondLevel(reason: "only after a request is chosen")),
                LineItem("join-decline", .secondLevel(reason: "only after a request is chosen")),
                LineItem(
                    "portal-",
                    .readingText(
                        reason:
                            "the portal rows come last; a press toggles \"In Home and Favorites\""
                    )),
            ]),
        .ratings: Area(
            views: ["RatingsSettings"],
            items: [
                LineItem("key"), LineItem("save"), LineItem("tmdb-key"), LineItem("tmdb-save"),
                LineItem("mal-key"), LineItem("mal-save"),
            ]),
        .appearance: Area(
            views: ["AppearanceSettings"],
            next: [
                "PortalShelfChoice": "behind \"Portal shelves\"",
                "ChannelShelfChoice": "behind \"Channel shelves\"",
                "ProviderShelfChoice": "behind \"Shelves from the provider catalog\"",
            ],
            items: [
                LineItem("theme"), LineItem("zu-symbol"), LineItem("zu-zeilen"), LineItem("zu-kopfbereich"),
                LineItem("vod"), LineItem("zu-portale"), LineItem("zu-sender"), LineItem("zu-kategorien"),
                LineItem("trailer"), LineItem("topshelf"),
                LineItem("icon-", .secondLevel(reason: "behind \"App icon\"")),
                LineItem("up-", .secondLevel(reason: "behind \"Rows on Home\"")),
                LineItem("down-", .secondLevel(reason: "behind \"Rows on Home\"")),
                LineItem("vis-", .secondLevel(reason: "behind \"Rows on Home\"")),
                LineItem("hero-", .secondLevel(reason: "behind \"In the Home header area\"")),
            ]),
        // **"Bild & Ton"** (AP59 N7): Audio track and subtitles in one section.
        .playback: Area(
            views: ["PlaybackSettings", "SubtitleSettings"],
            items: [
                LineItem("audio"), LineItem("anime"), LineItem("skip-intro"), LineItem("spoilers"),
                LineItem("still-watching"),
                LineItem("submode"),
                LineItem("subsize"),
                LineItem("subcolor"), LineItem("plainsubs"),
            ]),
        .live: Area(
            views: ["LiveSettings"],
            items: [
                LineItem("visible"), LineItem("browse"), LineItem("preview"), LineItem("adult-open"),
                LineItem("sport-sync"), LineItem("sport-auf"), LineItem("gruppen-auf"),
                LineItem("sportfilter-", .secondLevel(reason: "behind \"Sports\"")),
                LineItem("bulk-show", .secondLevel(reason: "behind \"Channel groups\"")),
                LineItem("bulk-hide", .secondLevel(reason: "behind \"Channel groups\"")),
                LineItem("block-", .secondLevel(reason: "behind \"Channel groups\"")),
                LineItem("check-", .secondLevel(reason: "behind \"Channel groups\"")),
                LineItem("up-", .secondLevel(reason: "behind \"Channel groups\"")),
                LineItem("down-", .secondLevel(reason: "behind \"Channel groups\"")),
                LineItem("group-", .secondLevel(reason: "behind \"Channel groups\"")),
            ]),
        // **Since AP59 N3 the management is the first level** — the row "Profile verwalten" in
        // front of it is gone. Pairing, handoff and remote have been under "Andere Geräte" since N7.
        .profiles: Area(
            views: ["ProfileSettings", "ProfileView"],
            items: [
                LineItem("anlegen"), LineItem("vorhandene"), LineItem("startwahl"), LineItem("umzug"),
                LineItem("zusammenlegen"), LineItem("entfernen"),
            ]),
        .devices: Area(
            views: ["OtherDevicesSettings"],
            next: ["CloudSheet": "behind \"Devices & Sharing\" — a sheet of its own above the section"],
            items: [LineItem("koppeln"), LineItem("vomHandy"), LineItem("fernkopplung")]),
        .language: Area(
            views: ["LanguageSettings"],
            items: [
                LineItem(
                    "lang-", .perCase(3, reason: "the three languages of the app (Deutsch, English, Türkçe)"))
            ]),
        .childLock: Area(
            views: ["ParentalControlsView"],
            next: [
                "PinForgottenSheet": "a full-screen sheet above the section, after \"Forgot PIN\"",
                "ApprovalSheet": "a full-screen sheet above the section, after \"Approvals\"",
                "Curtain": "stands in place of the section as long as it is locked",
                "LiveAllowList": "behind a child's row under \"Live for children\" (AP52)",
                "DeviceLockSheet":
                    "a full-screen sheet behind the row \"Device lock\" — switch, \"What the PIN locks\" and bar (G3)",
                "AdultSheet":
                    "a full-screen sheet behind the row \"Adult channels\" — both switches (G3)",
            ],
            items: [
                LineItem("pin"), LineItem("vergessen"), LineItem("geraet"),
                LineItem(
                    "grenze-", .perCase(AgeLimit.allCases.count + 1, reason: "every age limit and \"none\"")),
                LineItem("unverstanden"), LineItem("freigaben"), LineItem("erwachsen"),
                LineItem(
                    "live-",
                    .data(
                        typical: 2,
                        reason:
                            "one row per child profile under \"Live for children\" (AP52); one to two children"
                    )),
            ]),
        .storage: Area(
            views: ["StorageSettings"],
            items: [LineItem("sync"), LineItem("clear"), LineItem("cache-clear")]),
        .diagnostics: Area(
            views: ["DiagnosticsSettings"],
            items: [
                LineItem("debugMode"), LineItem("liveRenderer"), LineItem("ownDecoder"), LineItem("measure"),
                LineItem("sendLog"), LineItem("zustandsschau"), LineItem("log-notable"),
                LineItem("log-search"),
                LineItem(
                    "log-", .readingText(reason: "the log, limited to 620 pt in a focus section of its own")),
            ]),
        .about: Area(
            views: ["AboutSettings"],
            items: [
                LineItem("about-version"), LineItem("about-build"), LineItem("about-device"),
                LineItem("about-privacy"), LineItem("about-privacy-device"), LineItem("about-privacy-remove"),
                LineItem("about-report"), LineItem("about-licences"),
                LineItem("licence-", .readingText(reason: "the third-party packages, last in the section")),
                LineItem(
                    "about-tmdb",
                    .readingText(reason: "the TMDB notice its API terms require, after the licences")),
            ]),
    ]

    /// The upper bound of the done condition: **under** fifteen.
    static let limit = 15

    // MARK: - Reading

    static func sourceTexts() throws -> [String: String] {
        var texts: [String: String] = [:]
        for folder in ["Settings", "Accounts"] {
            for file in try SourceText.files(in: .features, subfolder: folder) {
                texts[file.name] = file.content
            }
        }
        return texts
    }

    /// The body of a view — from `struct Name: View {` to the closing brace in column one.
    static func bodyContent(_ name: String, in texts: [String: String]) -> String? {
        for text in texts.values {
            guard let start = text.range(of: "struct \(name): View {") else { continue }
            let rest = text[start.lowerBound...]
            let end = rest.range(of: "\n}\n")?.upperBound ?? rest.endIndex
            return String(rest[..<end])
        }
        return nil
    }

    /// Every identifier of a focus target in the body — and whether it is built further (`+`).
    static func identifiers(in bodyContent: String) -> [(identifier: String, built: Bool)] {
        let patterns = /(?:\bidentifier|\bid|\bequals|\bfirstTarget)\s*[:=]\s*"([^"\\]*)"(\s*\+)?/
        var found: [(String, Bool)] = []
        for row in bodyContent.split(separator: "\n") {
            let text = row.trimmingCharacters(in: .whitespaces)
            // Comments and the card's pills: Their focus is carried by the card, not by the row.
            guard !text.hasPrefix("//"), !text.contains("CardPill("), !text.contains("CardSelection(")
            else { continue }
            for match in text.matches(of: patterns) {
                found.append((String(match.output.1), match.output.2 != nil))
            }
        }
        return found
    }

    /// The views with their own focus that a body embeds — without the components.
    static func embedded(in bodyContent: String, texts: [String: String]) -> Set<String> {
        let blocks: Set<String> = [
            "DisclosureRow", "SwitchRow", "ChoiceRow", "ToggleRow", "ValueRow", "ActionRow",
            "InputRow", "FormButton", "SettingsCard",
        ]
        var names: Set<String> = []
        for match in bodyContent.matches(of: /\b([A-Z][A-Za-z]+)\(/) {
            let name = String(match.output.1)
            guard !blocks.contains(name), let other = Self.bodyContent(name, in: texts) else { continue }
            if other.contains(".focused(") || other.contains("focus: focus")
                || other.contains("focus: $focus")
            {
                names.insert(name)
            }
        }
        return names
    }
}

@Suite("Done condition: fewer than fifteen focus targets per section")
struct FocusPlanTests {

    @Test("Every section has a focus plan")
    func eachSectionHasAPlan() {
        for area in SettingsSection.allCases where FocusPlan.plan[area] == nil {
            Issue.record(
                "\(area.rawValue) has no focus plan — the done condition would be unchecked there")
        }
    }

    /// **The connection:** Every identifier in the source is in the plan, and every item in the
    /// plan is in the source.
    @Test("Every focus target is in the plan, and every item in the source text")
    func planAndSourceAgree() throws {
        let texts = try FocusPlan.sourceTexts()
        for (area, plan) in FocusPlan.plan {
            var found: [(identifier: String, built: Bool)] = []
            for view in plan.views {
                guard let bodyContent = FocusPlan.bodyContent(view, in: texts) else {
                    Issue.record("\(area.rawValue): view \(view) not found")
                    continue
                }
                found += FocusPlan.identifiers(in: bodyContent)
            }
            #expect(
                !found.isEmpty,
                "\(area.rawValue): not a single identifier read — the reading does not work")

            for (identifier, built) in found {
                guard let items = plan.items.first(where: { $0.identifier == identifier }) else {
                    Issue.record(
                        """
                        \(area.rawValue): focus target "\(identifier)\(built ? "…" : "")" is in no \
                        item. Every new target on the first level counts against the limit of \
                        \(FocusPlan.limit) — enter it with its count, or put it behind a row.
                        """)
                    continue
                }
                #expect(
                    !(built && items.count.isSingle),
                    "\(area.rawValue): \"\(identifier)…\" is built per entry and counted as one")
            }
            for items in plan.items where !found.contains(where: { $0.identifier == items.identifier }) {
                Issue.record(
                    "\(area.rawValue): item \"\(items.identifier)\" no longer exists in the source text")
            }
        }
    }

    /// **An embedded view with its own focus counts too** — otherwise everything in it would
    /// silently drop out of the count.
    @Test("Every embedded view with focus is accounted for")
    func embeddedViewsAreAccountedFor() throws {
        let texts = try FocusPlan.sourceTexts()
        for (area, plan) in FocusPlan.plan {
            guard let bodyContent = FocusPlan.bodyContent(plan.views[0], in: texts) else { continue }
            for name in FocusPlan.embedded(in: bodyContent, texts: texts)
            where !plan.views.contains(name) && plan.next[name] == nil {
                Issue.record(
                    "\(area.rawValue): \(name) brings its own focus targets and is in neither `views` nor `next`"
                )
            }
        }
    }

    @Test("No section has fifteen or more focus targets on the first level")
    func underFifteen() {
        for (area, plan) in FocusPlan.plan {
            let sum = plan.items.reduce(0) { $0 + $1.count.number }
            #expect(
                sum < FocusPlan.limit,
                "\(area.rawValue): \(sum) focus targets on the first level, fewer than \(FocusPlan.limit) are allowed"
            )
        }
    }

    /// **The enumerations count on the type and not in the plan.** Whoever adds an age limit
    /// should not have to enter anything here — the language is the exception because its type
    /// lives in the app target.
    @Test("The language choice offers as many languages as the plan counts")
    func languagesMatch() throws {
        let text = try SourceText.read("AppLanguage.swift", in: .tvApp)
        let cases = text.matches(of: /\n    case [a-z]+ = "[a-z]{2}"/).count
        #expect(cases == 3, "AppLanguage lists \(cases) languages, the plan counts three")
    }
}
