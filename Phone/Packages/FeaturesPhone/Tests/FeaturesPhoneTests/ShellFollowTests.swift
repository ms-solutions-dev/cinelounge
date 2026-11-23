import Testing

@testable import FeaturesPhone

/// **The bar follows the set-up and not the restart** (2026-09-07). Three
/// screenshots: channel list created in the settings, bridge found — and the
/// app carried on as if only the media server were there. `adopt` came exactly once, at the
/// end of the set-up; ``ShellModel/episode(_:)`` is the path for everything after.
@Suite("The bar follows the setup")
struct ShellFollowTests {

    @Test("A created channel list brings its tab without a restart")
    @MainActor
    func tabAppears() {
        let wrapper = ShellModel(catalogs: .fromAccesses(jellyfin: true))
        #expect(!wrapper.tabs.contains(.live))
        wrapper.episode(.fromAccesses(jellyfin: true, channelList: true))
        #expect(wrapper.tabs.contains(.live))
    }

    @Test("A deleted channel list takes its tab away again")
    @MainActor
    func tabDisappears() {
        let wrapper = ShellModel(
            catalogs: .fromAccesses(jellyfin: true, channelList: true))
        wrapper.episode(.fromAccesses(jellyfin: true))
        #expect(!wrapper.tabs.contains(.live))
    }
}
