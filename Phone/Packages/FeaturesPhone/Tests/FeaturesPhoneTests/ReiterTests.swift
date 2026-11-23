import Testing

@testable import FeaturesPhone

/// Without this table the tab marker wanders away on entering — and that is only
/// noticed on the device, because nothing fails in the process.
@Suite("Tabs and views")
struct TabTests {

    @Test("Six possible tabs, but never more than five at once")
    func fiveTabs() {
        // Six cases, because the favorites appear only if a place remains free.
        #expect(Tab.allCases.count == 6)
        for state in CatalogState.allCases {
            #expect(state.tabs.count <= Tab.atMost)
        }
    }

    @Test("Every tab has a title key and an icon pair")
    func tabsComplete() {
        for tabs in Tab.allCases {
            #expect(tabs.titleKey.hasPrefix("tab."))
            #expect(tabs.icon.outlined != tabs.icon.filled)
        }
    }

    /// The mapping on which it hangs: A detail page belongs to the library, a
    /// portal detail page to the portals, downloads and storage again to the library.
    @Test("The views highlight the right tab")
    func assignment() {
        #expect(ViewID.detail.tabs == .library)
        #expect(ViewID.detailFilm.tabs == .library)
        #expect(ViewID.downloads.tabs == .library)
        #expect(ViewID.storage.tabs == .library)
        #expect(ViewID.detailPortal.tabs == .portals)
    }

    /// The player and the remote have no tab and are still not an
    /// overlay: They lay themselves over everything and are not left with "Done".
    @Test("Overlay and full screen are two different things")
    func overlayVersusFullscreen() {
        #expect(ViewID.settings.isOverlay)
        #expect(ViewID.setup.isOverlay)
        #expect(!ViewID.player.isOverlay)
        #expect(!ViewID.remote.isOverlay)
        #expect(!ViewID.library.isOverlay)
    }

    @Test("Every view is either assigned to a tab or explicitly not")
    func noGap() {
        for view in ViewID.allCases {
            let hasTab = view.tabs != nil
            let isOnTop = view.isOverlay || view == .player || view == .remote
            #expect(hasTab != isOnTop, "\(view.rawValue) is neither one nor the other")
        }
    }
}
