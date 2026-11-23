import ParentalControls
import Testing

@testable import Features

/// The sidebar shows what the set-up sources carry (on-device test 2026-09-27, T13).
///
/// With only portals, "Live" and "Sport" were there and led to "Noch keine Sender
/// eingerichtet"; both asked only the child scope.
@Suite("Sidebar by source")
struct SidebarBySourceTests {

    private let pending = ChildScope(.pending)

    @Test("Without a channel list neither Live nor Sport")
    func withoutChannels() {
        let targets = AppSidebar.mainDestinations(scope: pending, hasPortals: true, hasChannels: false)
        #expect(!targets.contains(.live))
        #expect(!targets.contains(.sport))
        #expect(targets.contains(.portals))
    }

    @Test("With a channel list Live and Sport")
    func withChannels() {
        let targets = AppSidebar.mainDestinations(scope: pending, hasPortals: false, hasChannels: true)
        #expect(targets.contains(.live))
        #expect(targets.contains(.sport))
    }
}

/// **The wraparound follows the drawn sidebar** (on-device test 2026-09-30).
///
/// Since AP59 N3 the profile is at the top. The list for the wraparound still put it before
/// the settings: "Down" from the settings landed on "Start" instead of on the profile, "up"
/// from the profile on the search instead of on the settings.
@Suite("Sidebar: wrap-around at the edge")
struct SidebarCycleTests {

    private let targets = AppSidebar.mainDestinations(
        scope: ChildScope(.pending), hasPortals: true, hasChannels: true, hasJellyfin: true)

    @Test("Profile on top, Settings at the bottom — as drawn")
    func order() {
        #expect(
            targets == [
                .accounts, .search, .media, .jellyfin, .live, .sport, .vod, .portals, .favorites,
                .sync, .settings,
            ])
    }

    @Test("Down from Settings leads to the profile")
    func downFromSettings() {
        #expect(AppSidebar.wrapped(from: .settings, by: 1, in: targets) == .accounts)
    }

    @Test("Up from the profile leads to Settings")
    func upFromProfile() {
        #expect(AppSidebar.wrapped(from: .accounts, by: -1, in: targets) == .settings)
    }

    @Test("Nothing wraps in the middle of the sidebar")
    func inTheMiddle() {
        #expect(AppSidebar.wrapped(from: .search, by: -1, in: targets) == nil)
        #expect(AppSidebar.wrapped(from: .favorites, by: 1, in: targets) == nil)
    }
}
