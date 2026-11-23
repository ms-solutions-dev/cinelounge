import Core
import Foundation
import ParentalControls
import Testing

@testable import Features

private func title(_ id: String, approval: String?) -> MediaItem {
    MediaItem(id: id, kind: .movie, title: id, ageRating: approval)
}

/// A rule that applies: child account **and** a set PIN, limit at 12.
private let strict = ProtectionRule(
    deviceLocked: false, accountKind: .kind, isPinSet: true, limit: .from12)

// MARK: - The filter

/// **Without a lock everything gets through** — even what carries no rating.
@Test func withoutLockEverythingPassesThrough() {
    let list = [title("a", approval: "18"), title("b", approval: nil)]
    #expect(list.filter(ProtectionRule.pending.shows).count == 2)
}

/// What lies above the limit drops out.
@Test func aboveTheLimitDropsOut() {
    let list = [title("frei", approval: "6"), title("gesperrt", approval: "18")]
    let finished = list.filter(strict.shows)
    #expect(finished.map { $0.id } == ["frei"])
}

/// **No rating and an uninterpreted rating are two different things** — and are treated
/// differently.
///
/// ``ApprovalInterpretation`` knows three outcomes, and the difference between the last
/// two is a decision of the package:
///
/// * `.approval(alter)` — understood, is held against the limit.
/// * `.noRating` — the title carries **nothing**. Gets through.
/// * `.unrecognized` — the title carries something this app cannot classify. Drops out
///   as long as ``ProtectionRule/blocksUnrecognized`` applies.
///
/// **This test first stood wrong**, assuming `nil` drops out. It did
/// not, and the code was right: a title without a rating is the normal case — on
/// the media server by far not every one carries a rating. Blocking them all would mean
/// giving a child account an almost empty library; and exactly **that is why**
/// channels, portals and the provider catalog are not filtered but removed entirely
/// (see ``TabScope/withoutApprovals``) — there **nothing** carries a rating.
@Test func noValueLetsUnrecognizedThrough() {
    #expect([title("ohne", approval: nil)].filter(strict.shows).count == 1)
    #expect([title("leer", approval: "")].filter(strict.shows).count == 1)
    #expect([title("wirr", approval: "Nicht geprüft")].filter(strict.shows).isEmpty)
}

// MARK: - The tab scope

/// **Live and portals disappear in child mode — not dimmed, but gone.**
///
/// A dimmed entry is an invitation. And the reason is not strictness
/// but the lack of any basis: there are no ratings for channels and portals.
@Test func liveAndPortalsDropOut() {
    #expect(TabScope.remains("live", isInChildMode: true) == false)
    #expect(TabScope.remains("portale", isInChildMode: true) == false)
    #expect(TabScope.remains("mediathek", isInChildMode: true))
}

/// Ohne Kindermodus bleibt alles stehen.
@Test func withoutChildModeEverythingStays() {
    for tabs in ["live", "portale", "mediathek", "suche"] {
        #expect(TabScope.remains(tabs, isInChildMode: false))
    }
}

/// **What the tab removes, the Home screen must not deliver again.**
///
/// A channel that was still reachable via a start shelf would turn the
/// removed area into decoration.
@Test func removedItemsAreNotDeliveredLater() {
    #expect(TabScope.delivers("senderliste", isInChildMode: true) == false)
    #expect(TabScope.delivers("portale", isInChildMode: true) == false)
    #expect(TabScope.delivers("anbieter", isInChildMode: true) == false)
    #expect(TabScope.delivers("medienserver", isInChildMode: true))
}

// MARK: - The direct fetch (stage 4)

/// **What the list does not show, the funnel must not open.**
///
/// The filter from stage 2 filters lists; it does not filter paths. Whoever opens a title via the
/// Top Shelf marker, a deep link (`cinelounge://item/…`) or a remembered path
/// gets past every list. `MainView.open(_:in:using:)` is the only
/// funnel into a detail page and therefore asks the same question — tested here on the rule
/// itself, because the view has no test rig.
@Test func directFetchAsksTheSameQuestion() {
    let locked = title("ab18", approval: "18")
    let unrestricted = title("ab6", approval: "6")

    #expect(strict.shows(locked) == false)
    #expect(strict.shows(unrestricted))
    // Without a lock both open — otherwise the funnel would be a hurdle for adults.
    #expect(ProtectionRule.pending.shows(locked))
}

// MARK: - Account creation

/// **The marker applies exactly to the created account.**
@Test func exactlyThisAccountIsMarked() {
    let store = InMemoryStore()
    let list = ChildAccountList(store: store)
    let kind = ServerCredentials(
        server: URL(string: "https://haus-a.example/")!, user: "kind")
    let adult = ServerCredentials(
        server: URL(string: "https://haus-a.example/")!, user: "erwachsen")

    AccountCreation.mark(kind: true, forItem: kind, list: list)

    #expect(list.isChild(Account.Identifier(kind).stored))
    #expect(list.isChild(Account.Identifier(adult).stored) == false)
}

/// **Without a PIN the marker is information and not a lock** — and the screen says
/// so. Whoever concealed that would let someone believe they had protected their child.
@Test func withoutPinTheSetupSaysSo() {
    let store = InMemoryStore()
    #expect(AccountCreation.isPinSet(store: store) == false)
    _ = Pin(store: store).set("1234")
    #expect(AccountCreation.isPinSet(store: store))
}

extension ServerCredentials {
    /// Shorthand for the tests — the marker needs only server and user identifier.
    fileprivate init(server: URL, user: String) {
        self.init(serverURL: server, userID: user, username: user, accessToken: "x")
    }
}
