import Core
import Flows
import Foundation
import PlaylistKit
import PortalKit
import Testing

@testable import Features

/// **Where a title comes from** — AP29, 2026-09-11.
///
/// **The TV needs no new identifier scheme**, and that is the essential difference from the
/// phone: There every identifier carries its origin as a prefix, because it could not be
/// recognized otherwise. Here it can be read off the **form** of the identifier.
///
/// **What was missing was not the information but its place.** The same distinction was
/// written out in three places — when opening via the remote, in the phone project, and as
/// an enumerator of its own in ``DisruptionInterpretation``, which justified itself by saying that
/// the type "does not yet exist on the TV".
struct OriginTests {

    /// **A portal identifier consists of three parts, separated by `|`.**
    @Test("A portal identifier is recognised as a portal")
    func portalIdentifier() {
        let identifier = PortalItemID(
            portal: "serieshub", key: "s:chalk-line", address: "scheme://x")
        #expect(Origin.forItem(identifier: identifier.identifier) == .portals)
    }

    /// **A provider identifier carries its role as a section.**
    @Test("A provider identifier is recognised as a provider")
    func providerIdentifier() {
        #expect(Origin.forItem(identifier: "liste-1#movie#4711") == .provider)
        #expect(Origin.forItem(identifier: "liste-1#series#22") == .provider)
        #expect(Origin.forItem(identifier: "liste-1#episode#22#mkv") == .provider)
    }

    /// **And the same question one level up — with a trap that snapped shut.**
    ///
    /// For a **title** the two forms are far apart: The provider separates with `#`, the portal
    /// with `|`. For a **library** both use `|` and have three parts — `list|vod|4711` against
    /// `portal|search|entry`. ``PortalLibraryID`` accepts any middle part here,
    /// ``XtreamVODSource/parseLibraryID(_:)`` literally demands `vod` or `series` there.
    ///
    /// **The first version checked the wide form first**, and thereby swallowed the narrow one
    /// completely: Every provider category counted as a portal level. It was noticed only when
    /// ``MainView`` began to run through this switch — in the source the justification for the
    /// wrong order stood next to it, fully worded.
    @Test("A provider category is not a portal level")
    func libraryIdentifier() {
        #expect(Origin.forItem(library: "liste-1|vod|4711") == .provider)
        #expect(Origin.forItem(library: "liste-1|series|99") == .provider)
        #expect(
            Origin.forItem(library: PortalLibraryID(portal: "s", entry: "neu").identifier)
                == .portals)
        #expect(Origin.forItem(library: "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4") == .jellyfin)
    }

    /// **The wiring hangs on the origin and no longer on four copies.**
    ///
    /// Where the way back leads and which ladder the menu button takes stood at four call sites
    /// in ``MainView`` until 2026-09-11. Four copies of the same assignment drift apart as soon
    /// as an origin is added.
    @Test("Every origin knows its way back and its ladder")
    func wiring() {
        #expect(Origin.provider.sidebarDestination == .vod)
        #expect(Origin.portals.sidebarDestination == .portals)
        #expect(Origin.jellyfin.sidebarDestination == .media)

        // **Only whoever runs levels gets the step for it.** A provider category is a store —
        // "Action" has no subfolders; a portal entry leads further.
        #expect(Origin.portals.hasLevels)
        #expect(!Origin.provider.hasLevels)
        #expect(Origin.portals.ladder == FocusRules.portalLadder)
        #expect(Origin.provider.ladder == FocusRules.vodLadder)
        #expect(Origin.jellyfin.ladder == FocusRules.vodLadder)
    }

    /// **What both reject comes from the media server** — its identifiers are bare hex digits.
    ///
    /// **This is the most important of the three checks**, because it is the default: A mistake
    /// here would send a Jellyfin title over the bridge.
    @Test("Whatever has neither of the two forms comes from Jellyfin")
    func jellyfinIdentifier() {
        #expect(Origin.forItem(identifier: "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6") == .jellyfin)
        #expect(Origin.forItem(identifier: "") == .jellyfin)
        // A separator alone does not make a portal identifier — it needs three parts.
        #expect(Origin.forItem(identifier: "nur|zwei") == .jellyfin)
    }

    /// **The order is that of the sources and not that of the response times.**
    ///
    /// It decides what is at the top of a collected list; whoever answers first would otherwise
    /// determine a different sequence at every opening.
    @Test("The order is fixed and lists every origin exactly once")
    func order() {
        #expect(Origin.order == [.jellyfin, .provider, .portals])
        #expect(Set(Origin.order).count == Origin.allCases.count)
    }

    /// **Every origin has its own heading** — two identical ones would be two sections that look
    /// like one.
    @Test("No two origins share a heading")
    func headings() {
        let captions = Origin.allCases.map(\.headline)
        #expect(Set(captions).count == captions.count)
        #expect(captions.allSatisfy { !$0.isEmpty })
    }

    /// **The fault interpretation no longer keeps a second enumerator.**
    ///
    /// It stood there only because ``Origin`` did not exist — the file said so itself. Two
    /// enumerators over the same question drift apart as soon as a fourth source is added.
    @Test("Source kind is the same type as origin")
    func noSecondEnumerator() {
        let kind: DisruptionInterpretation.SourceKind = .portals
        #expect(kind == Origin.portals)
    }

    // MARK: - "Continue on the TV" (AP50, 24.09.2026)

    /// **Two origins with titles of the same name** — the check AP50 demands.
    ///
    /// "Morrowfeld" is on the media server **and** at animehub. If the **name** mattered, "continue
    /// watching on the TV" would send the viewer to the wrong source — and it would answer a
    /// foreign identifier with a fault ("It is reachable but cannot answer this request right
    /// now", on-device finding 2026-09-13).
    ///
    /// **The decision is made on the identifier, and only on it.** The string `origin` that
    /// the phone sends along is therefore **not** used for resolution: Two truths about the same
    /// question drift apart as soon as one side renames.
    @Test("Titles with the same name are told apart by identifier")
    func sameNamedTitlesByIdentifier() {
        let onTheServer = "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6"
        let inPortal = "animehub|serie|morrowfeld"

        #expect(Origin.forItem(identifier: onTheServer) == .jellyfin)
        #expect(Origin.forItem(identifier: inPortal) == .portals)
        #expect(Origin.forItem(identifier: onTheServer) != Origin.forItem(identifier: inPortal))
    }

    /// **An empty origin changes nothing** — and the case is not one from the workshop:
    /// ``SecondScreen/RemoteTests`` builds `spieleTitel(identifier: "", origin: "", …)`, so
    /// it exists over the wire.
    ///
    /// The identifier decides; if it is empty too, the media server applies, and the fetch fails
    /// there. **That is the point at which a message must stand** — before, a `return` stood
    /// there without a word, and a command that had arrived vanished silently.
    @Test("An empty origin falls back to Jellyfin and not into nothing")
    func emptyOriginFallsBackToJellyfin() {
        #expect(Origin.forItem(identifier: "") == .jellyfin)
    }

}
