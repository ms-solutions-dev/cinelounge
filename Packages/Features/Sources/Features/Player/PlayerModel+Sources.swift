import Core
import Flows
import Foundation
import ParentalControls
import PortalKit

extension PlayerModel {

    // MARK: - Source choice for a portal title (AP58 G1, A9)

    /// The portal behind the source — **also through the parental-controls filter.**
    var portalDataSource: PortalSource? {
        (source as? PortalSource) ?? ((source as? FilteredSource)?.source as? PortalSource)
    }

    /// Fetches what is on offer — **when the track board opens or the picture fails.**
    ///
    /// New on the TV: until then there was only "Try again" here, that is, the same dead source
    /// once more. A film from the media server has nothing to choose; there the choice stays
    /// empty and the board's section is missing.
    public func loadSourceChoice() async {
        guard target.kind == .recording, let portal = portalDataSource, let itemID = target.itemID
        else { return }
        await sourceChoice.load(forItem: itemID) {
            try await portal.host(forItem: itemID).map(PortalHost.init)
        }
        if sourceChoice.running == nil {
            sourceChoice.isRunning(await portal.lastSource, validUntil: await portal.lastValidUntil)
        }
    }

    /// Continues on another host — **at the same position, in the same player.**
    ///
    /// The running session signs off first: with an account that allows one connection, a
    /// session left open is the next refusal. **A new target without origin**, because "Try
    /// again" takes the origin (``PlaybackTarget/sourceURL``) — and that should be the new host
    /// afterwards, not the dead one.
    public func switchSource(zu row: PortalHost) async {
        guard let portal = portalDataSource, let itemID = target.itemID else { return }
        noteInteraction()
        isChoosingTracks = false
        let location = max(0, position)
        if let report = core.finish(at: location) { await send(report) }
        do {
            let stream = try await portal.stream(forItem: itemID, source: row.id)
            sourceChoice.isRunning(await portal.lastSource ?? row.id, validUntil: stream.validUntil)
            Diagnostics.playbackStep("Source switched: \(row.name) from \(Int(location)) s", since: nil)
            adopt(
                PlaybackTarget(
                    itemID: target.itemID, title: target.title, subtitle: target.subtitle,
                    url: stream.address, decision: target.decision, startAt: location,
                    duration: target.duration, seriesID: target.seriesID, media: target.media,
                    chapters: target.chapters,
                    preferredAudioLanguage: target.preferredAudioLanguage,
                    preferredSubtitleLanguage: target.preferredSubtitleLanguage,
                    kind: target.kind))
        } catch {
            Diagnostics.playbackProblem(
                "Source switch to \(row.name) failed: \(Diagnostics.explain(error))",
                since: nil)
        }
    }
}
