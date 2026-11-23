import Flows
import Foundation
import ProfileKit
import Testing

@testable import Features

/// The switches of A3 and A4 on the TV (AP88 wave 3) — **what a row says, where the focus lands,
/// which marks the head draws**; the order of the steps is checked at the core in `Flows`.
///
/// Language keys are put together here and not written out, so that `strings.py` does not count a
/// check as a use.
///
/// Counter-checks: with `copiedFrom` ignored in `SourcesView.look` ``copiedListsSayFromWhom()``
/// turns red; with Xtream offered offline in `ChannelListSheet.kinds` ``offlineOnlyM3U()``.
@Suite("Setup — A3 and A4 on the TV")
struct SetupSourcesTests {

    static let server = URL(string: "https://media.example:8096")!
    static let leaAccess = Access.jellyfin(server: server, userID: "lea-id", username: "lea")

    @Test("Every row state has its own sentence and mark")
    func rowLooks() {
        typealias Look = SourcesView.Look
        #expect(
            SourcesView.look(.jellyfin, .empty, copiedFrom: nil)
                == Look(caption: .empty(.jellyfin), badge: .add))
        #expect(
            SourcesView.look(.jellyfin, .found(detail: "Wohnzimmer"), copiedFrom: nil)
                == Look(caption: .foundOn("Wohnzimmer"), badge: .found))
        #expect(
            SourcesView.look(.jellyfin, .fromProfile(Self.leaAccess), copiedFrom: nil)
                == Look(caption: .fromProfile(user: "lea", host: "media.example"), badge: .confirm))
        #expect(
            SourcesView.look(.channelList, .suggested(from: "Anna"), copiedFrom: nil)
                == Look(caption: .suggested(from: "Anna"), badge: .takeOver))
        #expect(
            SourcesView.look(.portals, .waiting, copiedFrom: nil) == Look(caption: .waiting, badge: .waiting))
        #expect(
            SourcesView.look(.portals, .unavailable(.notForChildren), copiedFrom: nil)
                == Look(caption: .notForChildren, badge: .unavailable))
        #expect(
            SourcesView.look(.jellyfin, .unavailable(.noNetwork), copiedFrom: nil)
                == Look(caption: .noNetwork, badge: .unavailable))
    }

    @Test("A ✓ says what is there: the user, the host, or lists already on the device")
    func doneRows() {
        #expect(SourcesView.look(.jellyfin, .done(detail: "lea"), copiedFrom: nil).caption == .detail("lea"))
        #expect(SourcesView.look(.channelList, .done(detail: ""), copiedFrom: nil).caption == .ready)
        #expect(
            SourcesView.look(.channelList, .done(detail: "tv.example.com"), copiedFrom: nil).caption
                == .detail("tv.example.com"))
    }

    @Test("Lists taken over with one press say from whom, not a bare name")
    func copiedListsSayFromWhom() {
        let look = SourcesView.look(.channelList, .done(detail: "Anna"), copiedFrom: "Anna")
        #expect(look == SourcesView.Look(caption: .copied(from: "Anna"), badge: .done))
        #expect(
            SourcesView.look(.jellyfin, .done(detail: "lea"), copiedFrom: "Anna").caption == .detail("lea"),
            "only the IPTV row was copied")
    }

    @Test("The focus goes to the first open row, else to \"Done\"")
    func focus() {
        let open = SourcesPage(
            profile: Profile.Identifier(rawValue: "lea"),
            rows: [SourceRow(kind: .jellyfin, state: .done(detail: "lea"))], focus: .channelList)
        #expect(SourcesView.focusTarget(open) == SourcesView.rowID(.channelList))
        let finished = SourcesPage(profile: open.profile, rows: open.rows, focus: nil)
        #expect(SourcesView.focusTarget(finished) == SourcesView.doneID)
    }

    @Test("The rows carry the names of the sources, never \"portals\"")
    func sourceNames() {
        #expect(Access.Kind.allCases.map(SourcesView.sourceName) == ["Jellyfin", "IPTV", "CL-Server"])
        let area = "setup" + ".sources."
        #expect(SourcesView.badgeKey(.found) == area + "found")
        #expect(SourcesView.badgeKey(.add) == area + "add")
    }

    @Test("The head counts the three steps: profile, sources, done")
    func headMarks() {
        #expect(SetupStepHead.marks(at: .profile) == [.current, .ahead, .ahead])
        #expect(SetupStepHead.marks(at: .sources) == [.passed, .current, .ahead])
        #expect(SetupStepHead.marks(at: .done) == [.passed, .passed, .current])
    }

    @Test("A3 says \"Continue\" and \"Back\" in the setup, \"Save\" and \"Cancel\" elsewhere")
    func profileSheetButtons() {
        #expect(ProfileSheet.saveTitle(inSetup: true) == "setup" + ".continue")
        #expect(ProfileSheet.saveTitle(inSetup: false) == "common" + ".save")
        #expect(ProfileSheet.cancelTitle(inSetup: true) == "common" + ".back")
        #expect(ProfileSheet.cancelTitle(inSetup: false) == "common" + ".cancel")
    }

    @Test("§2.4 Without a network the IPTV sheet offers only M3U")
    func offlineOnlyM3U() {
        #expect(ChannelListSheet.kinds(online: false) == [.m3u])
        #expect(ChannelListSheet.kinds(online: true) == PlaylistAccess.Kind.allCases)
    }

    @Test("The form follows the offer: Xtream falls back to M3U when the network goes")
    func formFollowsOffer() {
        #expect(PlaylistLoginView.kind(.xtream, among: [.m3u]) == .m3u)
        #expect(PlaylistLoginView.kind(.xtream, among: [.xtream, .m3u]) == .xtream)
        #expect(PlaylistLoginView.kind(.m3u, among: [.xtream, .m3u]) == .m3u)
    }
}
