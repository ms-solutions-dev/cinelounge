/// Every half-height sheet of the app — as a **closed** enumeration.
///
/// Closed, so that "exactly one sheet at a time" can be checked and does not have to be
/// believed. Two open sheets on top of each other cannot be closed any more at 393 points.
///
/// All of them come from the bottom, all can be closed via grabber, cross or a tap beside
/// them.
public enum SheetID: String, CaseIterable, Sendable, Identifiable {

    // Catalog and sources
    case catalogChoice = "bestandWahl", portalChoice = "portalWahl", sources = "quellen", sourcesPortal =
        "quellenPortal", target = "ziel"

    // Second screen
    case keyboard = "tastatur"

    // Setup
    case systemPrompt = "systemabfrage", certificate = "zertifikat", certificateChanged =
        "zertifikatGeaendert"

    // Accounts
    case accountSwitch = "kontowechsel", carryOver = "mitwandern", pin

    /// Choose the profile picture (AP49) — **from the person sheet, as its replacement.**
    ///
    /// It opens only when ``accountSwitch`` is closed (``SheetState/close(following:)``): one
    /// sheet at a time, here too.
    case profileImage = "profilbild"

    /// The profile PIN (AP52): set, change, remove — **and the latch in front of the switch to
    /// a protected profile.** One sheet for both, because both are the same digit pad with the
    /// same way out (``ProfilePinState``).
    case profilePin = "profilpin"

    // Settings
    case deleteList = "listeLoeschen", signOut = "abmelden"

    // Downloads
    //
    // **Until 2026-09-09. `reise` stood here** — "For the trip": choose a duration, get a
    // suggestion, read the finish time. It was dropped by product decision. Requirement: this
    // view is not needed, only the downloads view.
    case titleMenu = "titelmenue", load = "laden", network = "netz", signInAgain = "neuAnmelden", taken =
        "belegt"

    // Detail page
    case ratings = "bewertungen", cast = "besetzung", filmography = "laufbahn", episodeMenu = "folgenmenue",
        before = "davor", season = "staffel"

    /// What the film database knows about a title you **do not** have.
    ///
    /// **"What you have opens; what you do not have explains itself."** Two thirds of the
    /// titles in a person's career are not in your own library; without this sheet those would
    /// be two thirds rows that stay silent on a press.
    case titleProfile = "titelprofil"

    // Live
    case channelGroups = "senderGruppen"

    // Player
    case trackSelection = "spurwahl"
    /// Cast, further episodes, similar — the TV's board as a sheet (AP58 G1, A4).
    case infoBoard = "infotafel"

    public var id: String { rawValue }

    /// The height as a **proportion** of the screen height, never as a number.
    ///
    /// A fixed height of 536 points would at Dynamic Type XXL not limit a tile but the whole
    /// screen — exactly what the rule forbids. The content scrolls, the sheet gets longer
    /// instead of fuller.
    public var portion: Double {
        switch self {
        // **The register has grown longer.** 0,45 carried three rows ("Jellyfin, Xtream VOD,
        // Downloads"); since AP12 there is one row per library, and on this server that is five
        // alone. `.large` as the second detent stays.
        case .catalogChoice: 0.63
        case .portalChoice, .target, .deleteList, .signOut, .before: 0.45
        // **The season selection is as tall as the register and for the same reason.** Twelve
        // seasons are twelve rows; a sheet that shows half of them replaces the scrolling of the
        // chip row with scrolling in the sheet and would have gained nothing.
        case .season: 0.63
        // **As tall as the register.** Poster, attributes, synopsis and cast one below the other
        // are not a menu with four rows; a flatter sheet would show the synopsis cut off, and
        // that is the reason you open it.
        case .titleProfile: 0.63
        // **As tall as the register, and for the same reason.** Behind the group selection lie 40
        // countries; a sheet that shows six of them replaces the horizontal swiping of the chip
        // row with vertical scrolling in the sheet and would have gained nothing. `.large` as the
        // second detent stays.
        case .channelGroups: 0.63
        // **At the ceiling and not above it.** At first 0,75 stood here; the check reported it,
        // and it is right: 0,70 is the upper limit, and what wants more wants `.large` and no
        // proportion — a sheet that covers almost everything is a screen with a grabber on top.
        //
        // **It is long and may be**, because the second detent carries it: The download sheet has
        // scope, resolution or variant and source, plus the rules; its loud button stands fixed
        // at the foot anyway.
        //
        // *Until 2026-09-09. `case .reise, .load` stood here — the trip is dropped.*
        case .load: 0.70
        // **Measured and not estimated.** The draft draws the person sheet 520 points tall
        // (`entwuerfe/prototyp.html`, `b-a-accountSwitch`, at 393 × 852); added to that is the
        // switch row of kids mode, which does not exist there yet — 59 points for the row and
        // about 18 for its two-line sentence. 597 of 852 is 0,70. Before, `default: 0.63` stood
        // here — the initial height for **a single** row.
        //
        // **On 2026-09-07 0,63 again**, recalculated and not reset: The row "Add account" is gone
        // (see ``AccountSwitchSheet``), and that is 59 points less — 538 of 852 is 0,63. That this
        // yields the same number as `default` is coincidence; the case therefore stays, along
        // with its measurement. Without it someone would have to redo it next time.
        case .accountSwitch: 0.63
        // **At the ceiling, and `.large` as the second detent.** Preview with title image and
        // circle, below it four rows of motifs and the save button at the foot — in the half
        // sheet only the first row of the grid would show.
        case .profileImage: 0.70
        // **At the ceiling like the image sheet, and `.large` as the second detent.** Head, four
        // dots and the digit pad in the lower third — the same height that the PIN sheet of
        // parental controls needs, only at the limit of this board.
        case .profilePin: 0.70
        default: 0.63
        }
    }
}
