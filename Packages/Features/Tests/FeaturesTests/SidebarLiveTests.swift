import Foundation
import Testing

@testable import Features

/// **The provider level under "Live".**
///
/// It was fully built — expanding, arrow, targets, focus return — and
/// remained invisible anyway: it hung on "only from two lists", and whoever has
/// one never saw that it exists. On 2026-08-22 the user wished for exactly this
/// level, **although it had long been there**. That is why the rule now
/// stands in a testable function and not only in a comment.
@Suite("The channel lists under “Live”")
@MainActor
struct SidebarLiveTests {

    private func provider(_ id: String) -> AppSidebar.LiveProvider {
        AppSidebar.LiveProvider(id: id, name: id, groups: [])
    }

    /// **Already with one list.** The arrow is then a path to a
    /// single row — but it says that lists live here and where a
    /// second would appear. That is the whole purpose of the change.
    @Test("One list is enough for the level")
    func oneListIsEnough() {
        // Since AP59 N5 the sidebar never expands — one chooses providers in the content.
        #expect(!AppSidebar.showsProviders(for: [provider("y-iptv")]))
    }

    /// Several anyway — that was so before and must not flip.
    @Test("Several lists still show the level")
    func severalListsStillShow() {
        #expect(!AppSidebar.showsProviders(for: [provider("a"), provider("b")]))
    }

    /// **Without a list no arrow.** An arrow with nothing behind it is a
    /// promise that the app does not keep — and "Live" is then a single
    /// entry that promises nothing.
    @Test("Without a channel list “Live” stays a single entry")
    func noListNoChevron() {
        #expect(!AppSidebar.showsProviders(for: []))
    }

    // MARK: - Movies & Series expands the same way

    /// **The same rule for both areas** (2026-08-22): since the rework "Movies & Series" shows
    /// the channel lists instead of the sections — the sidebar
    /// answers "where from", the surface "what". Two versions of the same
    /// decision would be one too many.
    @Test("The provider rule applies equally to Live and to Movies & Series")
    func oneRuleForBothAreas() {
        #expect(!AppSidebar.showsProviders(forIDs: ["y-iptv"]))
        #expect(!AppSidebar.showsProviders(forIDs: ["a", "b"]))
        #expect(!AppSidebar.showsProviders(forIDs: []))

        // And both paths through the same rule deliver the same.
        #expect(
            AppSidebar.showsProviders(for: [provider("y-iptv")])
                == AppSidebar.showsProviders(forIDs: ["y-iptv"]))
    }

    /// Section and provider both live under "Movies & Series" — otherwise
    /// the menu button would leave the area instead of going up one level.
    @Test("Provider and section live under Movies & Series")
    func vodDestinationsBelongToVOD() {
        #expect(AppSidebar.mainEntry(for: .vodProvider("y")) == .vod)
        #expect(AppSidebar.mainEntry(for: .vodProvider("y")) == .vod)
        #expect(AppSidebar.mainEntry(for: .liveProvider("y")) == .live)
    }

    // MARK: - The height of the expanded list

    /// **The finding of 2026-08-22:** Under a single channel list there was
    /// half a screen of emptiness, and "Movies & Series" was pushed to the bottom
    /// end. The cause was `maxHeight` on a `ScrollView` — it always takes
    /// what it is offered, and what was offered was the whole rest.
    @Test("A row gets the height of a row, not the rest of the screen")
    func oneRowTakesOneRow() {
        let height = AppSidebar.listHeight(forRows: 1)
        #expect(height == AppSidebar.groupRowHeight)
        #expect(height < AppSidebar.groupListHeight / 2, "otherwise the gap opens again")
    }

    /// Gaps count — otherwise the last row would be cut off.
    @Test("Several rows count their gaps too")
    func spacingCountsToo() {
        let three = AppSidebar.listHeight(forRows: 3)
        // With tolerance, as befits floating point — and not just
        // against a computed number: if someone changes ``groupRowHeight``,
        // the test should move along and not fire falsely.
        let expected = 3 * AppSidebar.groupRowHeight + 2 * AppSidebar.rowSpacing
        #expect(abs(three - expected) < 0.01)
    }

    /// **The cap stays.** Eighty groups must not push "Settings" out of
    /// the picture — that is what scrolling is for.
    @Test("Many rows do not run past the cap")
    func manyRowsStayCapped() {
        #expect(AppSidebar.listHeight(forRows: 200) == AppSidebar.groupListHeight)
    }

    /// No row, no height — otherwise an empty strip would remain.
    @Test("Without rows no area is left")
    func noRowsNoHeight() {
        #expect(AppSidebar.listHeight(forRows: 0) == 0)
    }

    // MARK: - What counts as a tvOS step

    /// **Entering from outside is not a step.** The timestamp
    /// ``AppSidebar/focusMovedAt`` serves solely to catch the straggler of a
    /// press that the focus itself has consumed. Whoever comes in from outside
    /// has pressed nothing in the sidebar — if a stamp were set here anyway,
    /// the first edge press afterwards was dead for a quarter of a second,
    /// and at the edge tvOS moves nothing on its own.
    @Test("Entering from outside does not count as a step")
    func entryIsNoStep() {
        #expect(!AppSidebar.isNativeStep(from: nil, to: .sport, assigned: nil))
    }

    /// **One's own assignment is not a step** — here the wraparound jump from
    /// "Settings" to "Library". It puts the focus on the
    /// opposite edge; whoever wants to undo the surprising jump immediately
    /// presses exactly there and exactly now.
    @Test("The own assignment does not count as a step")
    func ownAssignmentIsNoStep() {
        #expect(!AppSidebar.isNativeStep(from: .settings, to: .media, assigned: .media))
    }

    /// **Row to row is one** — and must stay one. The press that
    /// carries the focus within the sidebar to the edge is the case for
    /// which the edge-press check exists at all (double jump 2026-08-16).
    @Test("From row to row is a step")
    func rowToRowIsAStep() {
        #expect(AppSidebar.isNativeStep(from: .live, to: .vod, assigned: nil))
        // Even if something else was registered before.
        #expect(AppSidebar.isNativeStep(from: .live, to: .vod, assigned: .media))
    }

    /// When the focus leaves the sidebar there is nothing to stamp.
    @Test("Leaving the sidebar is not a step")
    func leavingIsNoStep() {
        #expect(!AppSidebar.isNativeStep(from: .live, to: nil, assigned: nil))
    }

    /// **The statement of the finding, as a chain.** After an entry the
    /// timestamp stays where it was — and therefore the first edge press
    /// afterwards counts again. Before, the entry stamped along, and
    /// ``AppSidebar/isEdgePress(lastFocusMove:now:)`` rejected the press.
    @Test("After entering, the first edge press counts again")
    func edgePressCountsAfterEntry() {
        let stamp = Date.distantPast
        #expect(!AppSidebar.isNativeStep(from: nil, to: .sport, assigned: nil))
        #expect(AppSidebar.isEdgePress(lastFocusMove: stamp, now: Date()))
    }

    // MARK: - Which row lights up

    /// If the focus is in the content, nothing lights up in the sidebar — otherwise there would
    /// be two bright spots in the picture, and neither would say where one is.
    @Test("Without focus in the sidebar nothing lights up")
    func nothingLitWithoutFocus() {
        #expect(AppSidebar.litRow(focus: nil, chosen: false, selection: .vod) == nil)
    }

    /// **The measured flash, as a test.** When entering from outside,
    /// tvOS assigns focus geometrically — here to "Sports" —, and the
    /// correction moves it only 20 ms later to "Movies & Series". For that long
    /// the wrong row lit up. Held in advance, the right one lights up at once.
    @Test("Assigned focus lights up the main entry")
    func assignedFocusLightsMainEntry() {
        let lit = AppSidebar.litRow(focus: .sport, chosen: false, selection: .vodProvider("y"))
        #expect(lit == .vod)
    }

    /// Whoever has walked has chosen — then the focus itself counts, otherwise
    /// one could no longer get away from the main entry with up and down.
    @Test("Navigated focus lights up itself")
    func chosenFocusLightsItself() {
        let lit = AppSidebar.litRow(focus: .sport, chosen: true, selection: .vodProvider("y"))
        #expect(lit == .sport)
    }
}
