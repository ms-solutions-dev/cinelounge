import Core
import Foundation
import ParentalControls
import SourceProbe
import Testing

@testable import Features

/// **Parental controls on the TV at parity with the phone** (G3, findings C8, C9, C10;
/// decisions 23, 27).
///
/// * **C8** — "Hide unlabeled adult channels" existed only on the phone.
/// * **C9** — "What the PIN locks" and the sidebar under device lock were only there.
/// * **C10** — The device switch was called "Kindermodus" on the phone (person sheet) and
///   "Kindersicherung an" (parental controls), on the TV "Gerätesperre". Now one word in one
///   place.
@MainActor
@Suite("Parental controls in parity")
struct ParentalControlsParityTests {

    // MARK: - C8

    static func channels(_ id: String, adult: Bool = false) -> Channel {
        Channel(
            id: id, name: id, streamURL: URL(string: "https://sender.beispiel/\(id)")!,
            playlistID: "liste", isAdult: adult)
    }

    /// **Since 2026-09-27 at the source** (check Live, finding 1): `LiveLibrary` filters, the
    /// TV's channel list receives the filtered catalog. The rule itself is tested by
    /// `ChannelBlockTests` in Core, every route by `ChannelSourceFilterTests` in PlaylistKit.
    @Test("The second rule applies in the TV's channel list")
    func unlabeled() {
        let m3u = [Self.channels("a"), Self.channels("b")]
        let preferences = LivePreferences()
        let strict = ChannelLock(hidesUnlabeled: true)
        #expect(LiveModel.visibleChannels(ChannelLock().filter(m3u), preferences: preferences).count == 2)
        #expect(
            LiveModel.visibleChannels(strict.filter(m3u), preferences: preferences).isEmpty,
            "a list without flagging disappears entirely")
        let xtream = [Self.channels("a"), Self.channels("x", adult: true)]
        #expect(
            LiveModel.visibleChannels(strict.filter(xtream), preferences: preferences).map(\.id) == ["a"],
            "a flagging list keeps its unflagged channels")
    }

    @Test("Switch and channel source read the same store as the phone")
    func wired() throws {
        let view = try SourceText.read("AdultSheet.swift", in: .features)
        #expect(view.contains("\"childLock.adult.hideUnmarked\""))
        #expect(view.contains("ChannelLock.write(hidesUnlabeled:"))
        let source = SourceText.strippingCommentLines(
            try SourceText.read("LiveLibrary.swift", in: .playlistKit))
        #expect(
            source.contains("lock: @escaping @Sendable () -> ChannelLock = { ChannelLock.stored() }")
        )
    }

    // MARK: - C9

    @Test("With a device lock, library, search, favorites and settings remain")
    func bar() {
        let adult = Dictionary(
            uniqueKeysWithValues: DeviceLockSheet.bar().map { ($0.title, $0.remains) })
        #expect(adult["tab.media"] == true)
        #expect(adult["tab.search"] == true)
        #expect(adult["tab.favorites"] == true)
        #expect(adult["settings.title"] == true, "behind the door, but there")
        for route in ["tab.live", "tab.vod", "tab.sport", "tab.portals"] {
            #expect(adult[route] == false, "\(route) remains with a device lock")
        }
        let kind = ProtectionRule(deviceLocked: false, accountKind: .kind, isPinSet: true).scope
        let childSidebar = Dictionary(
            uniqueKeysWithValues: DeviceLockSheet.bar(kind).map { ($0.title, $0.remains) })
        #expect(childSidebar["settings.title"] == false, "a child sees no administration")
    }

    @Test("What the PIN locks: the same doors as on the phone, each locked and justified")
    func doors() throws {
        for door in LockedDoors.info {
            #expect(LockedDoors.locked(door), "\(door)")
            #expect(LockedDoors.reason(door) != nil, "\(door)")
        }
        let view = try SourceText.read("DeviceLockSheet.swift", in: .features)
        #expect(view.contains("ForEach(LockedDoors.info"))
        let area = try SourceText.read("ParentalControlsView.swift", in: .features)
        #expect(area.contains("DeviceLockSheet(lock: lock)"), "the sheet hangs off the section")
        let phone = try SourceText.read("ParentalControlsView.swift", in: .featuresPhone)
        #expect(phone.contains("ForEach(LockedDoors.info"))
    }

    // MARK: - C10

    @Test("One wording for the device switch on both devices")
    func oneWord() throws {
        let tv = try SourceText.read("DeviceLockSheet.swift", in: .features)
        let phone = try SourceText.read("ParentalControlsView.swift", in: .featuresPhone)
        // **Since AP59 N4 no longer a switch on any device** — the device lock is gone.
        #expect(!tv.contains("titel: \"childLock.deviceLock\""))
        #expect(!phone.contains("titel: \"childLock.deviceLock\""))
        #expect(
            !(try SourceText.read("AccountSwitchSheet.swift", in: .featuresPhone)).contains("childMode"),
            "no second switch in the person sheet")
        let tvCatalog = try SourceText.read(.tvCatalog)
        let phoneCatalog = try SourceText.read(.phoneCatalog)
        #expect(!tvCatalog.contains("\"childLock.deviceModeToggle\""))
        #expect(!phoneCatalog.contains("\"childLock.on\""))
        #expect(!phoneCatalog.contains("\"accounts.childMode.text\""))
        #expect(
            AppLanguageSetting.word("childLock.deviceLock") != "childLock.deviceLock", "in the shared catalog"
        )
    }
}
