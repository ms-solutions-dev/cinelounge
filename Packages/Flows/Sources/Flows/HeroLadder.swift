import Core
import Foundation

/// **The tier ladder for the header area** — it is not "Jellyfin with a fallback".
///
/// **Since decision 27 (C4) on both devices** — until 2026-09-26 it lived on the phone.
/// On the TV the header stayed empty without a media server; now it fetches there as here, on
/// demand, titles from the provider catalog (tier 2).
///
/// The box answers the same question from **every** source. Until E20 it answered it
/// only if a media server was present; whoever set up the app with a channel list saw
/// an empty area above their shelves.
///
/// **The question changed on 09-06, and with it the first tier** (direction B to
/// K4, decided by the client). It used to be "what can I watch now" and
/// therefore began with **started items from the history**. Three findings overturned that:
///
/// * **The same question appeared twice on one screen.** Tier 1 was "started items",
///   and directly below it sits the "Continue Watching" shelf with the same entries — the
///   two hero images *were* the two frontmost tiles.
/// * **The box could not carry what tier 1 delivered.** A history entry
///   builds its ``HeroContent`` without logo, traits and rating; the traits line
///   (the box's traits line) is built and for every history hero **inevitably** stayed
///   empty. These were not forgotten assignments but two types that do not
///   fit together.
/// * **The box is sized for a different task.** The design gives it 300 points
///   of image and 140 points of text and fills them with "New in your library · Season 1 ·
///   71 episodes unwatched · 8.4 · Crime · Drama · Action". That is a **recommendation**,
///   not a continuation.
///
/// The question is now **"what's new"**, and the history answers it at
/// its own place — in the shelf below, which is built for it.
///
/// The order is a ranking, and each tier has its reason:
///
/// 1. **The media server**, mixed from the most recently added.
/// 2. **The provider catalog.** It supplies plot, genre, rating **and** a
///    background image — everything the box needs. But only on demand: The
///    images are only in `get_vod_info`, i.e. one request **per title**, and that
///    is worthwhile only if the tier above yields nothing.
/// 3. **Only a channel list?** Then no image box but **"On now"** —
///    different content, same place, same job.
/// 4. **Nothing set up** → the setup prompt that already exists.
///
/// **What is given up here is stated here and not only in the report:** the assurance
/// from E20 that the box "shows something even if no media server is set up".
/// That is exactly what the history tier was for. Tier 3 catches the most common of these cases
/// — a channel list without a server —, and whoever has set up only portals gets
/// **nothing** at the top and their shelves below. That is the flip side of the decision and not
/// an oversight.
public nonisolated enum HeroLadder {

    /// What the header area shows.
    public enum Tier<Held: Sendable & Equatable>: Sendable, Equatable {
        /// Titles of a source, with image and blurb.
        case title([Held])
        /// No image box: the running programme of the selected channels.
        case nowOnAir
        /// Nichts eingerichtet.
        case setUp

        /// The titles of this tier — empty for the other two.
        public var heroes: [Held] {
            if case .title(let heroes) = self { return heroes }
            return []
        }
    }

    /// - Parameters:
    ///   - geladen: what the sources brought along without being asked (tier 1)
    ///   - nachschlag: what a source delivers on request (tier 2). Empty until
    ///     somebody has asked — the ladder says via ``needsTopUp(_:)`` whether it
    ///     is worthwhile.
    ///   - fuehrtSenderliste: whether a channel list is set up (tier 3).
    public static func tier<Held>(
        loaded: [Held], lookup: [Held] = [], leadsWithChannelList: Bool
    ) -> Tier<Held> {
        if !loaded.isEmpty { return .title(loaded) }
        if !lookup.isEmpty { return .title(lookup) }
        return leadsWithChannelList ? .nowOnAir : .setUp
    }

    /// Whether the expensive request at tier 2 is worthwhile.
    ///
    /// **It costs one request per title.** Where the media server already yields something, it
    /// would be eight requests for a box that nobody gets to see.
    public static func needsTopUp<Held>(_ loaded: [Held]) -> Bool {
        loaded.isEmpty
    }

    /// **Tier 2: titles of the provider catalog, asked for individually.**
    ///
    /// The background image is not in the provider's category list but only in
    /// `get_vod_info` — one request **per title**. Therefore:
    /// * **one after the other and not side by side:** Eight simultaneous requests are, with this
    ///   provider, the start of an IP throttle that lasts minutes (documented on 08-15);
    /// * **at most twice as many attempts as places**, shuffled;
    /// * **only with a background image** — the box is ninety percent image.
    public static func lookup(
        candidates: [String], atMost: Int = HomeLayout.maxHeroes,
        shuffle: Bool = true, fetch: @Sendable (String) async -> MediaItem?
    ) async -> [MediaItem] {
        var found: [MediaItem] = []
        for identifier in (shuffle ? candidates.shuffled() : candidates).prefix(atMost * 2) {
            guard found.count < atMost else { break }
            guard let title = await fetch(identifier), title.artwork.backdropID != nil else { continue }
            found.append(title)
        }
        return found
    }
}
