import Core
import Foundation
import ParentalControls
import PlaylistKit

/// The channel source as a child sees it — **only the channels of its allow list**
/// (tvOS roadmap AP52, product decision 14 of 2026-09-25).
///
/// **The finding on the phone:** until here ``ParentalControls/TabScope`` removed Live
/// in child mode entirely, and every channel path hung on `rule.delivers("channelList")`. Since
/// the rule carries a ``ParentalControls/ChannelApproval``, the same question says "yes" for a
/// child with a list — and behind this yes stood, until now, the **entire** catalog of the
/// provider. The tab would have come back, with all 7,746 channels.
///
/// **A filter at the source and not at every screen.** Live tab, Live shelf of
/// Home, Favorites, Search and player all read via ``ChannelListingSource/channels()``; whoever
/// filters here filters on all six paths at once. A filter per screen would be the same rule
/// in six places — and forgotten at the seventh path.
///
/// **What the filter lets through is decided solely by ``ParentalControls/ChannelApproval/isAllowed(_:)``:**
/// no adult channel, no heading, the group is on the list. A new
/// group of the provider is never on it.
///
/// **There is no sports for a child.** The schedule computes over the programme of **all**
/// channels, and there is no allow list for sports — the same rule as on the TV,
/// where the sports area is always missing in child mode.
struct KidsChannelSource: ChannelListingSource {

    let source: any ChannelListingSource
    let approval: ChannelApproval

    func channels() async -> ChannelCatalog {
        let catalog = await source.channels()
        return ChannelCatalog(channels: approval.isVisible(catalog.channels), silent: catalog.silent)
    }

    func program(forItem channels: [Channel]) async -> [String: [Programme]] {
        await source.program(forItem: channels.filter(approval.isAllowed))
    }

    func freshProgramme() async -> Int { await source.freshProgramme() }

    func downloadsState() async -> ProgrammeState { await source.downloadsState() }

    func sport(from: Date, until: Date) async -> [SportEvent] { [] }

    /// **A favorite on a foreign channel is not set.** The path there leads
    /// through this filter anyway; the row here is the door in case someone finds it after all.
    func setEnabled(favorite channel: Channel) async -> Bool {
        guard approval.isAllowed(channel) else { return channel.isFavorite }
        return await source.setEnabled(favorite: channel)
    }

    func address(forItem channel: Channel) async -> URL {
        await source.address(forItem: channel)
    }

    func dailyProgramme(forItem channel: Channel) async -> [Programme] {
        guard approval.isAllowed(channel) else { return [] }
        return await source.dailyProgramme(forItem: channel)
    }

    /// The iPad grid (B10) — **asked only for permitted channels.**
    func gridProgramme(
        forItem channels: [Channel], from: Date, until: Date
    ) async -> [String: [Programme]] {
        await source.gridProgramme(forItem: channels.filter(approval.isAllowed), from: from, until: until)
    }
}
