import ParentalControls
import Testing

@testable import FeaturesPhone

@Suite("Signpost")
@MainActor
struct SignpostTests {

    @Test("Back leads to where one came from — not to Home")
    func back() {
        let w = Navigator()
        w.tabs = .library
        w.show(.detail)
        #expect(w.current == .detail)
        w.back()
        #expect(w.current == .library)
    }

    /// Whoever goes from the library into a detail page, switches to the Live tab and comes
    /// back stands in the detail page again.
    @Test("Each tab keeps its stack")
    func stackPerTab() {
        let w = Navigator()
        w.tabs = .library
        w.show(.detail)
        w.tabs = .live
        #expect(w.current == .live)
        w.tabs = .library
        #expect(w.current == .detail)
    }

    /// The diagnostics are reachable from setup **and** from settings. The way back carries
    /// the wording of the door — otherwise it says "to settings" although one came from setup.
    @Test("The way back carries the word of the door")
    func wordOfTheDoor() {
        let fromSettings = Navigator()
        fromSettings.show(.settings)
        fromSettings.show(.diagnose)
        #expect(fromSettings.doorClosed(.diagnose) == .settings)

        let fromSetup = Navigator()
        fromSetup.show(.setup)
        fromSetup.show(.diagnose)
        #expect(fromSetup.doorClosed(.diagnose) == .setup)
    }

    @Test("An overlay lies above the tab, and the bar disappears with it")
    func overlay() {
        let w = Navigator()
        w.tabs = .live
        #expect(w.highlightedTab == .live)
        w.show(.settings)
        #expect(w.highlightedTab == nil)
        w.back()
        #expect(w.highlightedTab == .live)
    }

    @Test("\"Done\" clears the whole overlay, not just one step")
    func done() {
        let w = Navigator()
        w.show(.settings)
        w.show(.channelLists)
        w.show(.newChannelList)
        w.done()
        #expect(w.overlay.isEmpty)
        #expect(w.current == .start)
        #expect(w.doorClosed(.channelLists) == nil)
    }

    /// **The finding of 2026-09-09:** *"when I tap 'Storage' in settings, the view only opens when
    /// I tap 'Done'."*
    ///
    /// Storage is the only settings area with a tab — it belongs to the library because it is
    /// also reached from downloads. That put it in the stack **of the tab**, which lies under
    /// the cover of the settings. So what is tested is not whether the step happens — it always
    /// did — but **in which stack** it lands.
    @Test("From Settings the storage page stays in the overlay")
    func memoryStaysInOverlay() {
        let w = Navigator()
        w.tabs = .start
        w.show(.settings)
        w.show(.storage)

        #expect(w.overlay == [.settings, .storage])
        #expect(w[.library].isEmpty, "Nothing may lie under the ceiling")
        #expect(w.current == .storage)

        // And the way back goes up one level, not out of the overlay.
        w.back()
        #expect(w.overlay == [.settings])
    }

    /// **Without an open overlay the tab still applies.** The path from downloads into storage
    /// is exactly the case for which the mapping "storage belongs to the library" was made —
    /// it must not change with it.
    @Test("From downloads the storage page stays in the tab")
    func memoryFromDownloads() {
        let w = Navigator()
        w.tabs = .library
        w.show(.downloads)
        w.show(.storage)

        #expect(w.overlay.isEmpty)
        #expect(w.views(.library) == [.downloads, .storage])
    }

    /// A running picture covers **everything** and is not left with "Done" — it does not
    /// belong in the overlay even when one is open.
    @Test("The player never goes into the overlay")
    func playerNotInOverlay() {
        let w = Navigator()
        w.tabs = .library
        w.show(.settings)
        w.show(.player)

        #expect(w.overlay == [.settings])
        #expect(w.views(.library) == [.player])
    }

    /// A detail page lights up its tab, even three levels deep.
    @Test("The highlighted tab follows the view")
    func highlightedTab() {
        let w = Navigator()
        w.tabs = .library
        w.show(.downloads)
        #expect(w.highlightedTab == .library)
        w.show(.storage)
        #expect(w.highlightedTab == .library)
    }

    /// **The finding of 2026-09-05** The shell gave every `NavigationStack` the same binding, and
    /// it read the stack of the *currently selected* tab — all five hung on one.
    @Test("Each tab has its own stack, including the unselected one")
    func stacksAreSeparate() {
        let navigator = Navigator()
        navigator.tabs = .library
        navigator.show(.detail)

        // Read from outside, without switching the tab.
        #expect(navigator.views(.library) == [.detail])
        #expect(navigator[.live].isEmpty)

        // And written from outside, likewise without switching.
        navigator[.live] = [ViewPath(.player, slot: 0)]
        #expect(navigator.views(.library) == [.detail])
        #expect(navigator.path.map(\.view) == [.detail])
    }

    /// Whoever deletes a channel list and sets up another would otherwise stand in the detail
    /// page of a title that does not exist on the new provider.
    @Test("The stack of a vanished tab is deleted")
    func vanishedTab() {
        let navigator = Navigator()
        navigator.tabs = .live
        navigator.show(.detail)
        #expect(navigator.views(.live) == [.detail])

        navigator.adapt(.fromAccesses(jellyfin: true))

        #expect(navigator[.live].isEmpty)
        #expect(navigator.tabs == .start, "The selection must lie in the new bar")
    }

    /// A `filter` creates holes, and a hole in the stack is only noticed when going back —
    /// then one stands at a place nobody called up.
    @Test("A remaining stack is truncated at the front, not filtered")
    func stackIsTruncated() {
        let navigator = Navigator()
        navigator.tabs = .library
        navigator[.library] = [
            ViewPath(.detail, slot: 0), ViewPath(.downloads, slot: 1),
            ViewPath(.storage, slot: 2),
        ]

        // The Library tab stays, but without downloads two of its views are gone.
        navigator.adapt(.fromAccesses(jellyfin: true))
        #expect(navigator.views(.library) == [.detail, .downloads, .storage])

        // If the tab itself disappears, the whole stack disappears.
        navigator.adapt(.fromAccesses(portals: true))
        #expect(navigator[.library].isEmpty)
    }

    /// The overlay lies above the bar and belongs to no tab — the setup that triggers this
    /// change is itself one.
    @Test("The overlay survives a changed setup")
    func overlaySurvives() {
        let navigator = Navigator()
        navigator.show(.setup)
        navigator.adapt(.fromAccesses(jellyfin: true, channelList: true, portals: true))
        #expect(navigator.overlay == [.setup])
        #expect(navigator.highlightedTab == nil)
    }

    /// Across all transitions: afterwards the selection is in the bar, and no stack contains a
    /// view that no longer exists.
    @Test("No transition leaves the selection or stack invalid")
    func everyTransitionIsClean() {
        for previous in CatalogState.allCases where previous.isSetUp {
            for after in CatalogState.allCases where after.isSetUp {
                let navigator = Navigator()
                navigator.tabs = previous.tabs.last ?? .start
                for tabs in previous.tabs {
                    navigator[tabs] = [ViewPath(tabs.root, slot: 0)]
                }

                navigator.adapt(after)

                #expect(after.tabs.contains(navigator.tabs))
                for tabs in Tab.allCases {
                    let route = navigator[tabs]
                    #expect(route.isEmpty || after.tabs.contains(tabs))
                    #expect(route.allSatisfy { after.reached($0.view) })
                }
            }
        }
    }

    /// Finding of 2026-09-07 on the device: A tap on "Asil" opened "Kobe Runaways".
    ///
    /// The payload hung on the ``ViewID``, so there was exactly **one** for all
    /// detail pages. Whoever opened the second overwrote the first — and on going back the
    /// wrong title appeared.
    @Test("Two detail pages carry two different titles")
    func twoDetailPagesTwoTitles() {
        let navigator = Navigator()
        navigator.tabs = .library

        navigator.show(.detail, title: "ali")
        navigator.show(.detail, title: "tokyo")

        let stack = navigator[.library]
        #expect(stack.count == 2, "Two calls are two stack slots")
        #expect(stack[0] != stack[1], "…and two distinguishable path values")
        #expect(navigator.title(zu: stack[0]) == "ali")
        #expect(navigator.title(zu: stack[1]) == "tokyo")

        // And the way back leads to the title one came from.
        navigator.back()
        #expect(navigator.title(zu: navigator.path[0]) == "ali")
    }

    /// The second part of the same finding: "Morrowfeld does nothing at all."
    ///
    /// If `.detail` was already in the stack, a second call appended the same value once
    /// more — SwiftUI cannot tell two equal values apart, the path grew and the view stayed
    /// put.
    @Test("The same title twice still yields two different paths")
    func sameTitleTwice() {
        let navigator = Navigator()
        navigator.tabs = .library

        navigator.show(.detail, title: "morrowfeld")
        navigator.show(.detail, title: "morrowfeld")

        #expect(Set(navigator[.library]).count == 2)
    }

    /// The job must survive the PIN prompt — otherwise parental controls open a detail page
    /// without a title after four correct digits.
    @Test("A job behind a locked door arrives completely")
    func jobSurvivesGatekeeper() {
        let navigator = Navigator()
        navigator.tabs = .library
        navigator.gatekeeper = {
            $0 == .detail ? .door(identifier: "detail", reason: "") : nil
        }

        navigator.show(.detail, title: "locked")
        #expect(navigator[.library].isEmpty, "Nothing opens before the PIN")

        navigator.letPass()
        #expect(navigator.title(zu: navigator.path[0]) == "locked")
    }
}
