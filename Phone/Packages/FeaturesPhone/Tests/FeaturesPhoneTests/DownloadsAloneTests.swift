import Testing

@testable import FeaturesPhone

/// Without a bar there is a stack, and the router must point to it.
///
/// The finding of 2026-09-13 on the device: In the downloads without a network a tap on a poster did
/// nothing. The router put the detail page into the stack of the tab it
/// stood on — and that was not the library, whose stack is the only one visible.
@Suite("Downloads alone")
@MainActor
struct DownloadsAloneTests {

    @Test("Without a tab bar a tap on downloads lands on the library stack")
    func tapLandsVisible() {
        let wrapper = ShellModel(catalogs: .fromAccesses(jellyfin: true, channelList: true))
        wrapper.navigator.tabs = .live
        wrapper.enterDownloadsAlone()
        wrapper.navigator.show(.detail, title: "downloads:abc")
        #expect(wrapper.navigator[.library].map(\.view) == [.detail])
        #expect(wrapper.navigator[.live].isEmpty)
    }

    @Test("The library stack stays in place on entering")
    func stackStays() {
        let wrapper = ShellModel(catalogs: .fromAccesses(jellyfin: true))
        wrapper.navigator.tabs = .library
        wrapper.navigator.show(.detail, title: "abc")
        wrapper.navigator.tabs = .start
        wrapper.enterDownloadsAlone()
        #expect(wrapper.navigator.tabs == .library)
        #expect(wrapper.navigator[.library].map(\.view) == [.detail])
    }
}
