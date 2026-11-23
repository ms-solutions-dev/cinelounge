import Foundation

/// Which states **must have** a way out — and which expressly have none.
///
/// **The guard over the list and not over a single case.** Without it the
/// enumeration grows, and some case again has only a sentence: "Sign-in expired" without
/// a button is a dead end — and dead ends were a package of their own on the TV (E28).
/// The check walks both lists against ``PlaybackPhase/form``; whoever introduces a state
/// and enters it in neither is caught.
///
/// **Two lists and no rule.** "Everything that is an error needs a button" is
/// wrong, in both directions: "The one connection is in use" is an error
/// **without** an action, "All channel groups hidden" is not one and has one anyway.
///
/// **Since R3 (2026-09-26) for both devices.** The phone had no such list, and
/// exactly there three states carried a button that did not change the situation (see
/// ``PlaybackPhase/form``).
public nonisolated enum InfoVersusAction {

    /// States that **must** carry a button — one each with the reason.
    ///
    /// * **The way back to sign-in** (``PlaybackPhase/loginExpired``) and **to
    ///   setup** (``PlaybackPhase/notSetUpYet``) — without them the app is shut.
    /// * **Try again**, where exactly that is the action: a silent source, a
    ///   broken-off title, an expired address, a TV that is just waking up.
    /// * **The way to the switch that caused the situation** — hidden groups,
    ///   missing channel list, the bridge address, the downloads rules, the camera.
    /// * **A way back of its own per origin** (AP39): provider access, profile choice and
    ///   pairing of the portals.
    /// * **The certificate prompt** — the button brings it out; without it the screen
    ///   would be information about something the viewer is meant to decide.
    public static let needsAction: Set<PlaybackPhase> = [
        .loginExpired, .notSetUpYet,
        .networkJellyfin, .networkXtream, .jellyfinWontPlay, .jellyfinDisruption,
        .portalAddressExpired, .networkTV,
        .emptyLiveHidden, .emptyLiveWithoutList, .networkPortals, .cellularPaused,
        .cameraDenied,
        .xtreamDeliversNothing,
        .xtreamAccessExpired, .portalProfileRequired, .portalLoginRequired,
        .certificateUnconfirmed,
    ]

    /// States that **expressly carry no** button — one each with its reason.
    ///
    /// * **No network: the button would be at the router** (``PlaybackPhase/noConnection``), and in
    ///   airplane mode the answer lies in the downloads, which the quiet path opens.
    /// * **Still loading** — the action is waiting.
    /// * **Empty is empty.** A "Reload" button above an empty library
    ///   promises that something will change.
    /// * **Waiting is the only action** with the connection in use; a "Retry"
    ///   would use it up a second time.
    /// * **A raw stream, a distrustful system player, a bridge that has rejected**
    ///   — a second press fails at the same place.
    /// * **The cancellation** shows nothing; it has nothing to report.
    ///
    /// **Enumerated and not "the rest".** A case that gets through neither of the two lists
    /// should stand out.
    public static let withoutAction: Set<PlaybackPhase> = [
        .noConnection, .networkAirplaneMode,
        .loadingStart, .loadingLong, .portalFetchAddress,
        .emptyLibrary, .emptyFavorites, .emptySearch, .emptyPortalLevel,
        .xtreamBusy,
        .xtreamRawStreamOnly, .certificateSystemPlayer, .portalUnresolvable,
        .abort,
    ]

    /// Whether this state carries a button — **read from the shape and not from the
    /// list.** The lists say what **should** be; this question says what **is**.
    public static func hasAction(_ state: PlaybackPhase) -> Bool {
        state.form.hasButton
    }
}
