import Flows
import Foundation

extension HeroLadder {

    /// The step for a ``CatalogState`` — the ladder itself has been in ``Flows/HeroLadder``
    /// since decision 27 (C4), shared with the TV.
    ///
    /// **Step 3 stays empty on the phone** (see `StartView.headerArea`): "Live today" answers
    /// the same question one row further down. The TV does the same.
    public static func tier(
        loaded: [HeroContent], lookup: [HeroContent] = [], state: CatalogState
    ) -> Tier<HeroContent> {
        tier(loaded: loaded, lookup: lookup, leadsWithChannelList: state.hasKey(.channelList))
    }
}
