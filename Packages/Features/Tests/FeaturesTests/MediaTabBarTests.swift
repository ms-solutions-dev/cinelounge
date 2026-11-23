import Core
import Testing

@testable import Features

/// Checks the focus rule of the tab pill.
///
/// The rule exists because tvOS chooses the target of a movement geometrically: from
/// the content going up, focus landed on "Start", the tab on the far left —
/// and because the pill switches while moving, the
/// area changed along with it. The answer is to make only the active tab reachable
/// from outside. **Both error directions of this rule have already occurred:** the
/// after-the-fact correction via `onChange` visibly jumped from "Start" to the
/// active tab, and `focusable(_:)` on the buttons shut the whole pill
/// down — no tab was reachable any more. That is why the rule now stands as its
/// own function and is pinned down here.
@Suite("Tab pill")
/// On the main actor, because the rules being checked live there (AP15,
/// 2026-09-02): the warning gate turns "nonisolated calls MainActor" into a
/// failure — and in substance it always was one.
@MainActor
struct MediaTabBarTests {

    @Test("From outside exactly the active tab is reachable")
    func onlyActiveTabIsReachableFromOutside() {
        for section in MediaTabBar.Section.allCases {
            let reachable = MediaTabBar.isReachable(section, selection: .series, focus: nil)
            #expect(
                reachable == (section == .series),
                "from outside only the active tab may take focus"
            )
        }
    }

    @Test("Inside the pill all tabs are reachable")
    func allTabsAreReachableFromWithin() {
        // Otherwise one could no longer move left and right — the pill
        // would be a trap with exactly one button.
        for section in MediaTabBar.Section.allCases {
            #expect(MediaTabBar.isReachable(section, selection: .series, focus: .home))
        }
    }

    @Test("Some tab is always reachable")
    func someTabIsAlwaysReachable() {
        // The inverse of the bug that prompted this test suite: with
        // `focusable(_:)` the pill was shut down completely, and the press up
        // fizzled out silently.
        for selection in MediaTabBar.Section.allCases {
            let reachable = MediaTabBar.Section.allCases.contains { section in
                MediaTabBar.isReachable(section, selection: selection, focus: nil)
            }
            #expect(reachable, "the pill must never become unreachable")
        }
    }
}

/// Which areas the pill shows — **an empty one is not there.**
///
/// **The finding of 2026-09-12:** `ForEach(Section.allCases)` ran unfiltered. Start ·
/// Series · Movies · Home Videos were always there, even without a single
/// home-video library. ``AppSidebar`` writes down two files further on why that is
/// wrong — *"Without it there would be a row with four empty pages, and that looks
/// like a bug, not like a missing setup"* — and hides the
/// whole media library without a server. **Inside**, the four nevertheless stayed fixed; the same
/// rule stopped at the threshold.
@Suite("The pill's sections")
struct MediaTabBarSectionsTests {

    private func library(_ kind: Core.Library.Kind) -> Core.Library {
        Core.Library(id: kind.rawValue, name: String(describing: kind), kind: kind)
    }

    /// **Empty means "not loaded yet", and then the pill shows everything.**
    ///
    /// **The regression of 2026-09-12:** the function returned `[.home]` for an empty list
    /// — an *answer*, and so the fallback "empty means all"
    /// never kicked in. ``MainView``'s library list is only fetched the first time "Movies"
    /// is opened; on Home it was empty, and only "Start" was left: the way
    /// into an area depended on information that only comes into being once you go in.
    @Test("Without libraries nothing is known — not \"nothing present\"")
    func emptyMeansUnknown() {
        #expect(MediaTabBar.sections(forItem: []).isEmpty)
    }

    /// **Start always stays, as soon as anything at all is known.** It carries the shelves,
    /// and those exist even without a media server — from portals, provider and channel list.
    @Test("Portals only yields Home alone")
    func homeStays() {
        #expect(MediaTabBar.sections(forItem: [library(.portalLevel)]) == [.home])
    }

    @Test("Series only yields Home and Series")
    func seriesOnly() {
        #expect(MediaTabBar.sections(forItem: [library(.series)]) == [.home, .series])
    }

    /// **Music, channels and portal levels carry no media-library area** — they have
    /// their own places in the sidebar.
    @Test("Music, channels and portals open no section of the pill")
    func foreignKindsDoNotCount() {
        let found = MediaTabBar.sections(forItem: [library(.music), library(.liveTV), library(.portalLevel)])
        #expect(found == [.home])
    }

    /// **And a hidden shelf takes no area with it.** The pill asks the
    /// **libraries** and not the shelves: a shelf is also missing when someone has
    /// switched it off or ``ShelfRule/perOrigin`` has capped it, and neither
    /// is a statement about whether there are movies.
    @Test("Eleven movie libraries yield the Movies section, even above the shelf cap")
    func cappingTakesNoSection() {
        let many = (1...11).map { Core.Library(id: "m\($0)", name: "Filme \($0)", kind: .movies) }
        #expect(MediaTabBar.sections(forItem: many) == [.home, .movies])
    }

    @Test("All three kinds yield all four sections")
    func allFour() {
        let found = MediaTabBar.sections(
            forItem: [library(.series), library(.movies), library(.homeVideos)])
        #expect(found == Set(MediaTabBar.Section.allCases))
    }
}
