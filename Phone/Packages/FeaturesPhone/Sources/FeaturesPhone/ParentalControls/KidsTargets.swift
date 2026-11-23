import ParentalControls

/// What a child reaches on the phone — **the mapping of the views onto the shared
/// targets** (``ParentalControls/ChildTarget``, AP58 R1).
///
/// **The rule is in the package** (``ParentalControls/ChildScope/isAllowed(_:)``): a child
/// reaches titles, search, favorites, downloads, player and legal texts, Live only with its
/// allow list; portals, provider catalog, sports and the management are for it not
/// locked but **not present**. Parents come in via the profile switch with their
/// profile PIN (decision 20). Here it only says which view is which target.
///
/// **Since R1 as on the TV also for Live and portals.** Until then this list let a
/// child reach every Live and portal view, and only the tab scope took the tabs
/// away; a jump from outside landed there anyway.
enum KidsTargets {

    /// The neutral target of a view.
    static func target(_ view: ViewID) -> ChildTarget {
        switch view {
        case .start, .library, .detail, .detailFilm: .mediaLibrary
        case .live: .live
        case .portals, .detailPortal: .portals
        case .favorites: .favorites
        case .search: .search
        case .downloads: .downloads
        case .player, .remote: .player
        case .about, .privacy, .licenses: .legalTexts
        case .storage, .setup, .accounts, .newAccount, .migration, .certificates, .handoff,
            .parentalControls, .forgotPin, .approvals, .settings, .channelLists,
            .newChannelList, .portalSettings, .report, .editChannelList,
            .liveSettings, .groups, .playback, .ratingsSettings, .appearance,
            .arrangeShelves, .diagnose, .log, .accountSettings, .cloud, .otherDevices,
            .pinReset, .profile, .profileChanged:
            .administration
        }
    }

    /// Whether this view is not reachable under this rule.
    static func locked(_ view: ViewID, rule: ProtectionRule) -> Bool {
        !rule.scope.isAllowed(target(view))
    }
}
