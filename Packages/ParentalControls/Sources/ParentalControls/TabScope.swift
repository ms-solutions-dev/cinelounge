import Foundation

/// The tab bar does not look the same for everyone.
///
/// **In child mode Live and portals disappear — not dimmed, but gone.** A dimmed tab is an
/// invitation: it says "there is something here that you may not", and that is exactly the
/// information that makes a child search. What is not there is not searched for.
///
/// **The reason is not strictness but the lack of any basis.** For channels and portals there
/// are **no ratings**: 7,746 channels without an age statement, and a portal catalog is read
/// off, not licensed. There is nothing there on which a limit could rest — so it applies to the
/// whole area or not at all.
///
/// **Three tabs for this account, five for the others.** So the design says, and it is the same
/// sentence with which `CatalogState` generates its tabs: a tab appears if its source is there —
/// here a second condition is added.
public enum TabScope {

    /// Which sources drop out in child mode.
    ///
    /// **As a set and not as an `if` at the bar.** The same question is asked by the search (two
    /// catalogs fewer) and the catalog choice (the provider row drops out); three places with the
    /// same rule would be three opportunities to answer it differently.
    public static let dropsOut: Set<String> = ["live", "portale"]

    /// Ob dieser Reiter im Kindermodus bleibt.
    public static func remains(_ tabs: String, isInChildMode on: Bool) -> Bool {
        remains(tabs, isInChildMode: on, deselected: [])
    }

    /// The same question with the **second** reason: the viewer does not want it.
    ///
    /// **Three reasons, and each says something different.** A tab appears if it **exists**
    /// (`CatalogState`), if it is **allowed** (child mode) and if it is **wanted** (this list).
    /// Merging them would be convenient and would lose the information: "Live is missing because no
    /// list is there" and "Live is missing because you switched it off" lead to different next
    /// steps.
    ///
    /// **Deselected and not allowed — the same direction as everywhere here.** If a tab is added, it
    /// is there without further action.
    public static func remains(
        _ tabs: String, isInChildMode on: Bool, deselected: Set<String>
    ) -> Bool {
        guard !deselected.contains(tabs) else { return false }
        guard on else { return true }
        return !dropsOut.contains(tabs)
    }

    /// The same question with the **allow list for channels** (AP52, decision 14).
    ///
    /// **Live comes back only with a list that allows something.** The reasoning above still holds:
    /// channels carry no age statements. The ``ChannelApproval`` does not replace the missing basis,
    /// it is one of its own — a parent looked at the groups and named them. Without such a choice
    /// the tab stays away; sports and portals always stay so, because there is no list for them.
    public static func remains(
        _ tabs: String, isInChildMode on: Bool, deselected: Set<String>,
        channelApproval: ChannelApproval
    ) -> Bool {
        if tabs == "live", on, !deselected.contains(tabs) {
            return !channelApproval.isEmpty
        }
        return remains(tabs, isInChildMode: on, deselected: deselected)
    }

    /// Whether the **channel list** may deliver channels in child mode — only with a
    /// ``ChannelApproval`` that allows something, and then only its channels
    /// (``ChannelApproval/isAllowed(_:)``).
    public static func deliversChannels(isInChildMode on: Bool, channelApproval: ChannelApproval) -> Bool {
        guard on else { return true }
        return !channelApproval.isEmpty
    }

    /// Whether this origin may still deliver titles in child mode.
    ///
    /// **The same rule for catalogs, search and Home shelves.** A channel that could still be
    /// reached via Home after all would turn the removed tab into decoration.
    public static func delivers(_ origin: String, isInChildMode on: Bool) -> Bool {
        guard on else { return true }
        return !withoutApprovals.contains(origin)
    }

    /// The origins that **carry no ratings** — and therefore drop out entirely.
    ///
    /// **The provider catalog stands here, and that is a finding and not strictness.**
    /// `MediaItem.ageRating` is filled in **one** place in the whole shared set, and that is the
    /// media server (`JellyfinKit/ItemMapping`). An Xtream catalog does not deliver the value at
    /// all; any interpretation of it would be `noRating`, and "no statement" passes. The age
    /// limit would thus act on **nothing** there — it would stand as a number on the screen and
    /// leave ten thousand titles untouched.
    ///
    /// **There are only two honest answers to that**, and the third would be the worst: either let
    /// everything through and say so, or take the area away. It is taken away, because the same
    /// reasoning already holds for channels and portals — and because an area that alone stayed
    /// unfiltered would be exactly the gap that makes the lock implausible.
    public static let withoutApprovals: Set<String> = ["senderliste", "portale", "anbieter"]
}
