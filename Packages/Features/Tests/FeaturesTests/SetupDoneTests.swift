import Flows
import Foundation
import ProfileKit
import Testing

@testable import Features

/// A7 on the TV (AP88 wave 5) — **which sources the last page lists and with which sentence**; the
/// start choice and "Add another profile" are checked at the core in `Flows`.
///
/// Counter-checks: with `.empty` rows kept in `SetupDoneView.lines` ``onlyDoneAndWaiting()`` turns
/// red; with `copiedFrom` dropped there ``copiedListsSayFromWhom()``.
@Suite("Setup — A7 on the TV")
struct SetupDoneTests {

    @Test("A7 lists only what is done or waiting, in the order of A4")
    func onlyDoneAndWaiting() {
        let rows = [
            SourceRow(kind: .jellyfin, state: .done(detail: "lea")),
            SourceRow(kind: .channelList, state: .empty),
            SourceRow(kind: .portals, state: .waiting),
        ]
        #expect(
            SetupDoneView.lines(rows, copiedFrom: nil) == [
                SetupDoneView.Line(kind: .jellyfin, caption: .detail("lea"), waiting: false),
                SetupDoneView.Line(kind: .portals, caption: .waiting, waiting: true),
            ])
    }

    @Test("IPTV taken over from another profile says from whom, lists already here say so")
    func copiedListsSayFromWhom() {
        let copied = [SourceRow(kind: .channelList, state: .done(detail: "Lea"))]
        #expect(SetupDoneView.lines(copied, copiedFrom: "Lea").map(\.caption) == [.copied(from: "Lea")])
        let ready = [SourceRow(kind: .channelList, state: .done(detail: ""))]
        #expect(SetupDoneView.lines(ready, copiedFrom: nil).map(\.caption) == [.ready])
    }

    @Test("Unavailable rows never reach A7")
    func unavailableIsLeftOut() {
        let rows = [
            SourceRow(kind: .jellyfin, state: .unavailable(.noNetwork)),
            SourceRow(kind: .portals, state: .unavailable(.notForChildren)),
            SourceRow(kind: .channelList, state: .done(detail: "Anbieter")),
        ]
        #expect(SetupDoneView.lines(rows, copiedFrom: nil).map(\.kind) == [.channelList])
    }

    @Test("The focus ids of A7 are distinct")
    func distinctFocus() {
        let ids = [
            SetupDoneView.startID, SetupDoneView.anotherID, SetupDoneView.startChoiceID,
            SetupDoneView.childLimitID,
        ]
        #expect(Set(ids).count == ids.count)
    }
}
