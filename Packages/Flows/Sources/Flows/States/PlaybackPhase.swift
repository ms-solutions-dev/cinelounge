import Foundation

/// Every state one of the two apps can show — **a closed list, not a
/// toolkit, and since 2026-09-26 one for both devices.**
///
/// **Why this is a type and not a collection of calls.** Without it every view builds
/// its own error text, and two views interpret the same failure differently.
/// That was exactly the finding on the phone of 2026-09-06: `PlayerModel` translated **every**
/// error of every source into "No response from the media server" — over an Xtream broadcast.
///
/// **Why it is shared** (AP58 R3, report A finding S5, report B findings 9 and 10). Until
/// 2026-09-26 the type existed twice, with the same case names and different
/// content: of 17 shared states, 9 carried different title keys, 13 of 22
/// shared `state.*` keys a different sentence, and only 5 the same icon. A
/// viewer with TV and phone saw two screens for the same situation — and on the
/// phone an Xtream 401 led to the sign-in at the media server, on the TV to the
/// channel lists. Here form, key and icon now live **once**; drawing still happens
/// per platform (`StateView` on the TV and on the phone).
///
/// **The union of both lists.** Some cases are produced by only one platform — the
/// TV has no airplane mode, the phone no certificate prompt in operation. They
/// remain cases, and ``tvOnly`` and ``phoneOnly`` say which; each
/// platform's showcase presents only its own.
///
/// **All texts live in the shared `WordingKit` catalog under `state.*`** — heading,
/// sentence, button, side path. A key is never additionally in an app catalog; the two
/// `strings.py` enforce that.
public nonisolated enum PlaybackPhase: String, CaseIterable, Sendable, Identifiable {

    // MARK: - Loading

    /// The ordinary loading spinner.
    case loadingStart = "ladenStart"
    /// **Not a case of its own but the second stage of ``loadingStart``** — the same
    /// spinner, a few seconds later, with a sentence added. Whoever says nothing while it
    /// takes time leaves the viewer guessing whether anything is happening at all.
    case loadingLong = "ladenLang"

    // MARK: - Leer

    /// The server answers, it just has nothing here.
    case emptyLibrary = "leerBibliothek"
    /// Nothing saved — **an invitation, not a malfunction.**
    case emptyFavorites = "leerFavoriten"
    case emptySearch = "leerSuche"
    /// All channel groups are hidden — the list is not empty, it is hidden.
    case emptyLiveHidden = "leerLiveAusgeblendet"
    /// No channel list is configured at all.
    ///
    /// This case and ``emptyLiveHidden`` deliberately look different: the one
    /// can be undone with a switch, the other demands a setup.
    case emptyLiveWithoutList = "leerLiveOhneListe"
    /// A folder of a portal without a single entry.
    ///
    /// **Empty is an answer, not an error** (viewer finding 2026-08-28). For a portal an
    /// empty folder is a normal case. **And expressly not ``emptyLibrary``**: its
    /// sentence refers to the media server.
    case emptyPortalLevel = "leerPortalebene"

    // MARK: - Netz

    /// **This TV has no way onto the network at all** (AP25, 2026-09-11).
    ///
    /// A TV without a network cable and one with the server switched off looked the
    /// same until then. **Without a button:** "Retry" cannot bring about a missing
    /// network cable. The phone shows ``networkAirplaneMode`` for the same situation — there
    /// the downloads are on the device, and they are the answer.
    case noConnection = "keineVerbindung"
    /// Airplane mode on the phone — the app has tried nothing, and the downloads play immediately.
    case networkAirplaneMode = "netzFlugmodus"
    /// The media server is in the house and silent.
    case networkJellyfin = "netzJellyfin"
    /// The provider comes from the internet — **not a word about the tunnel.**
    case networkXtream = "netzXtream"
    /// The portals bridge does not answer.
    case networkPortals = "netzPortale"
    /// **The TV does not answer the remote on the phone.**
    ///
    /// A case of its own and not ``networkJellyfin``: the media server is not involved in a
    /// remote, and the next step is "is the TV on".
    case networkTV = "netzFernseher"

    /// **The server answers, the system player does not** (TestFlight, 2026-09-07).
    ///
    /// The system player has its own network stack and does not know the app's trust.
    /// Set only when the caller reports the situation expressly, never guessed.
    case certificateSystemPlayer = "zertifikatSystemplayer"
    /// **A breakdown in the engine is not a network error.** The server has answered — otherwise
    /// the failure would come from the source and not from the player.
    case jellyfinWontPlay = "jellyfinSpieltNicht"
    /// **The server answers — and reports an error** (AP25, 2026-09-11).
    ///
    /// A case of its own and not ``networkJellyfin``: "The server reports a malfunction" and
    /// "No response" send the viewer to different places. 404, 400 and 500
    /// collapse here because they mean the same to the viewer.
    case jellyfinDisruption = "jellyfinStoerung"

    // MARK: - Sign-in

    /// The sign-in at the **media server** is no longer valid — a task, not an error.
    case loginExpired = "anmeldungAbgelaufen"
    /// No source is configured yet.
    case notSetUpYet = "nochNichtEingerichtet"
    /// **The server's certificate is waiting for an answer** — in live operation
    /// (AP39, 2026-09-20).
    ///
    /// The connection delegate puts the question into `CertificatePrompt`; without this state
    /// whoever set up their server anew saw "No response" from then on. Only the TV
    /// passes the mailbox to the interpretation (see ``tvOnly``).
    case certificateUnconfirmed = "zertifikatUnbestaetigt"

    // MARK: - Dropout

    /// The state that expressly shows **nothing**.
    ///
    /// It arises on the phone at the audio interruption — a call, a switch to another
    /// app. Whoever comes back afterwards has made no mistake; the old content stays.
    case abort = "abbruch"

    // MARK: - Provider

    /// **The account allows one connection, and it is running elsewhere.**
    ///
    /// The provider gives no error identifier of its own for this; it rejects the address, and
    /// the engine sees that as a breakdown. In a household with a TV **and** a phone
    /// this is everyday.
    case xtreamBusy = "xtreamBelegt"
    /// The channel is no longer in the access — the list may have changed since loading.
    /// Not a network error.
    case xtreamDeliversNothing = "xtreamLiefertNichts"
    /// **A raw stream is not a connection in use** (finding 2026-09-06).
    ///
    /// "In use" can be refuted by the address: the extension was chosen by the access. Since
    /// AP2 the app remuxes itself; if a raw stream fails anyway, it is the stream
    /// or the supply.
    case xtreamRawStreamOnly = "xtreamNurRohstrom"
    /// **The provider's access is no longer valid** — not the same as an expired
    /// sign-in at the media server (on the TV AP39, on the phone AP58 wave 1).
    ///
    /// Both once fell into ``loginExpired``, and the button led to the
    /// **media server account**, where a provider password cannot be changed.
    case xtreamAccessExpired = "xtreamZugangAbgelaufen"

    // MARK: - Portale

    /// The address is valid for five minutes and has expired.
    case portalAddressExpired = "portalAdresseVerfallen"
    /// The CL-Server is fetching the address — **a progress indicator and not an error.**
    ///
    /// Until 2026-10-01 the case was called `portalRueckfall` and said "Trying via another
    /// path …" — on **every** start, even when the first path worked (in seven days of
    /// server log: seven of seven). Whoever read that waited for a malfunction that did
    /// not exist.
    case portalFetchAddress = "portalAdresseHolen"
    /// The bridge has answered and rejected, with a reason it names verbatim.
    case portalUnresolvable = "portalNichtAufloesbar"
    /// **The device is paired and does not yet belong to a person** — `auth.profile_required`.
    case portalProfileRequired = "portalProfilNoetig"
    /// **The sign-in at the portal service is no longer valid** — `auth.required`.
    case portalLoginRequired = "portalAnmeldungNoetig"

    // MARK: - Phone only

    /// Paused because "Download on Wi-Fi only" is switched on.
    case cellularPaused = "mobilfunkAngehalten"
    /// **The camera is denied** — the only state whose way leads out of the app,
    /// into the system settings.
    case cameraDenied = "kameraVerweigert"

    public var id: String { rawValue }

    // MARK: - Which platform produces it

    /// States that **only the TV** produces — and that the phone therefore does not
    /// showcase.
    ///
    /// * ``noConnection`` — the phone says the same as ``networkAirplaneMode``, with the
    ///   downloads as the answer.
    /// * ``certificateUnconfirmed`` — only the TV passes the mailbox of the
    ///   certificate prompt to the interpretation; on the phone nobody takes it out, and a
    ///   state whose question is never asked would sit above every error.
    /// * ``emptyPortalLevel`` — the phone shows empty portal folders in its portal view.
    ///
    /// **`scripts/buttons.py` in the phone reads this list**: a state here needs no
    /// producer there.
    public static let tvOnly: Set<PlaybackPhase> = [
        .noConnection, .certificateUnconfirmed, .emptyPortalLevel,
    ]

    /// States that **only the phone** produces: a TV has no airplane mode,
    /// no cellular, no camera, no audio interruption by a call — and it
    /// is itself the TV the remote is looking for.
    public static let phoneOnly: Set<PlaybackPhase> = [
        .networkAirplaneMode, .networkTV, .abort, .cellularPaused, .cameraDenied,
    ]

    // MARK: - Wie er aussieht

    /// Whether it explains something, demands something, waits, or shows nothing.
    ///
    /// **The difference between information and task is the whole point of this type.**
    /// An information state says what is; a task state says what one can do. Which state
    /// has which form is guarded by ``InfoVersusAction``.
    ///
    /// **Where the two versions contradicted each other, the TV applies** (decision
    /// 20, TV benchmark), each for its own reason:
    ///
    /// * ``emptyLiveHidden`` is a **task** ("Show groups") and not an
    ///   information state with a quiet path: the way into the live settings is the only one that
    ///   changes the situation — so the loud one.
    /// * ``networkPortals`` leads to the **portal settings** and not to the second
    ///   attempt: the sentence asks "is its address correct?", and that is found there.
    /// * ``certificateSystemPlayer`` is an **information state**. On the phone it carried "Try
    ///   again", and the second attempt fails at the same place.
    /// * ``xtreamBusy`` is an **information state**. On the phone it carried "Check where it
    ///   is running", and the button tried again — it used up the one allowed
    ///   connection a second time. Waiting is the action here.
    /// * ``portalUnresolvable`` is an **information state**: the bridge rejected and named the
    ///   reason. On the phone it carried "Look at reason", and the button reloaded; the
    ///   TV shows the reason verbatim as an addition.
    /// * ``portalFetchAddress`` is a **loading sentence** and not a showcased path probe. On the phone
    ///   ``RouteProbe/fallbackViaBridge`` stood here — an example with invented
    ///   states that, as a form, asserted steps nobody had measured.
    /// * The buttons of ``loginExpired``, ``emptyLiveWithoutList``,
    ///   ``xtreamAccessExpired`` and ``xtreamDeliversNothing`` lead **to where the
    ///   situation can be changed** (account, channel lists, sync). On the phone they all only tried
    ///   to reload — under the label "Sign in again".
    ///
    /// What the phone brings along stays: the quiet path into the downloads (`sidePath`) and the
    /// gold color for a state that costs time or money (`costs`). The TV
    /// draws neither.
    public var form: StateForm {
        switch self {

        case .loadingStart:
            return .load(LoadingInfo(message: "state.loading.library"))
        case .loadingLong:
            return .load(
                LoadingInfo(
                    message: "state.loading.library", slowImmediately: true,
                    sidePath: "state.downloads.meanwhile"))

        case .emptyLibrary:
            return .info(
                StateInfo(
                    icon: "film.stack", headline: "state.library.empty.title",
                    message: "state.library.empty.text"))
        case .emptyFavorites:
            return .info(
                StateInfo(
                    icon: "heart", headline: "state.favorites.empty.title",
                    message: "state.favorites.empty.text"))
        case .emptySearch:
            return .info(
                StateInfo(
                    icon: "magnifyingglass", headline: "state.search.empty.title",
                    message: "state.search.empty.text", sidePath: "state.search.empty.side"))
        case .emptyLiveHidden:
            return .job(
                Job(
                    icon: "eye.slash", headline: "state.live.allHidden.title",
                    message: "state.live.allHidden.text", button: "state.live.allHidden.action",
                    target: .liveSettings))
        case .emptyLiveWithoutList:
            return .job(
                Job(
                    icon: "dot.radiowaves.left.and.right",
                    headline: "state.live.noList.title", message: "state.live.noList.text",
                    button: "state.live.noList.action", target: .channelLists))
        case .emptyPortalLevel:
            return .info(
                StateInfo(
                    icon: "folder", headline: "state.portal.empty.title",
                    message: "state.portal.empty.text"))

        case .noConnection:
            return .info(
                StateInfo(
                    icon: "wifi.slash", headline: "state.net.none.title",
                    message: "state.net.none.text"))
        case .networkAirplaneMode:
            return .info(
                StateInfo(
                    icon: "airplane", headline: "state.offline.title",
                    message: "state.offline.text", sidePath: "state.offline.side"))
        case .networkJellyfin:
            return .job(
                Job(
                    icon: "server.rack", headline: "state.net.jellyfin.title",
                    message: "state.net.jellyfin.text", button: "state.retry", target: .retry,
                    sidePath: "state.downloads.meanwhile"))
        case .networkXtream:
            return .job(
                Job(
                    icon: "dot.radiowaves.left.and.right",
                    headline: "state.net.xtream.title", message: "state.net.xtream.text",
                    button: "state.retry", target: .retry))
        case .networkPortals:
            return .job(
                Job(
                    icon: "globe", headline: "state.net.portals.title",
                    message: "state.net.portals.text", button: "state.portals.settings",
                    target: .portalSettings, sidePath: "state.downloads.meanwhile"))
        case .networkTV:
            return .job(
                Job(
                    icon: "tv.and.hifispeaker.fill",
                    headline: "state.tv.unreachable.title",
                    message: "state.tv.unreachable.text", button: "state.tv.unreachable.action",
                    target: .retry))

        case .certificateSystemPlayer:
            return .info(
                StateInfo(
                    icon: "lock.trianglebadge.exclamationmark",
                    headline: "state.cert.player.title", message: "state.cert.player.text"))
        case .jellyfinWontPlay:
            return .job(
                Job(
                    icon: "play.slash", headline: "state.jellyfin.stalled.title",
                    message: "state.jellyfin.stalled.text", button: "state.retry", target: .retry))
        case .jellyfinDisruption:
            return .job(
                Job(
                    icon: "exclamationmark.triangle",
                    headline: "state.jellyfin.fault.title",
                    message: "state.jellyfin.fault.text", button: "state.retry", target: .retry))

        case .loginExpired:
            return .job(
                Job(
                    icon: "person.crop.circle.badge.exclamationmark",
                    headline: "state.login.expired.title",
                    message: "state.login.expired.text", button: "state.login.expired.action",
                    target: .accounts, sidePath: "state.downloads.meanwhile"))
        case .notSetUpYet:
            return .job(
                Job(
                    icon: "sparkles", headline: "state.setup.none.title",
                    message: "state.setup.none.text", button: "state.setup.none.action",
                    target: .setup))
        case .certificateUnconfirmed:
            return .job(
                Job(
                    icon: "lock.trianglebadge.exclamationmark",
                    headline: "state.cert.ask.title", message: "state.cert.ask.text",
                    button: "state.cert.ask.action", target: .certificate))

        case .abort:
            return .muted

        case .xtreamBusy:
            return .info(
                StateInfo(
                    icon: "person.2.slash", headline: "state.xtream.busy.title",
                    message: "state.xtream.busy.text", sidePath: "state.downloads.meanwhile"))
        case .xtreamDeliversNothing:
            return .job(
                Job(
                    icon: "questionmark.circle", headline: "state.xtream.missing.title",
                    message: "state.xtream.missing.text", button: "state.sync", target: .sync))
        case .xtreamRawStreamOnly:
            return .info(
                StateInfo(
                    icon: "waveform.badge.exclamationmark",
                    headline: "state.xtream.raw.title", message: "state.xtream.raw.text"))
        case .xtreamAccessExpired:
            return .job(
                Job(
                    icon: "person.crop.circle.badge.exclamationmark",
                    headline: "state.xtream.expired.title",
                    message: "state.xtream.expired.text", button: "state.xtream.expired.action",
                    target: .channelLists))

        case .portalAddressExpired:
            return .job(
                Job(
                    icon: "clock.badge.exclamationmark",
                    headline: "state.portal.expired.title",
                    message: "state.portal.expired.text", button: "state.portal.expired.action",
                    target: .retry, costs: true))
        case .portalFetchAddress:
            return .load(LoadingInfo(message: "state.portal.fetching"))
        case .portalUnresolvable:
            return .info(
                StateInfo(
                    icon: "globe.badge.chevron.backward",
                    headline: "state.portal.unresolved.title",
                    message: "state.portal.unresolved.text"))
        case .portalProfileRequired:
            return .job(
                Job(
                    icon: "person.crop.circle", headline: "state.portal.profile.title",
                    message: "state.portal.profile.text", button: "state.portal.profile.action",
                    target: .portalSettings))
        case .portalLoginRequired:
            return .job(
                Job(
                    icon: "person.crop.circle.badge.exclamationmark",
                    headline: "state.portal.login.title", message: "state.portal.login.text",
                    button: "state.portal.login.action", target: .portalSettings))

        case .cellularPaused:
            return .job(
                Job(
                    icon: "antenna.radiowaves.left.and.right",
                    headline: "state.cellular.paused.title",
                    message: "state.cellular.paused.text", button: "state.cellular.paused.action",
                    target: .downloadRules, costs: true))
        case .cameraDenied:
            return .job(
                Job(
                    icon: "camera", headline: "state.camera.denied.title",
                    message: "state.camera.denied.text", button: "state.camera.denied.action",
                    target: .systemSettings))
        }
    }

    /// The icon of this state — **a name from SF Symbols, drawn in the
    /// platform.** `nil` if it carries none (loading, silent).
    public var icon: String? { form.icon }

    /// The heading as a key in the shared catalog.
    public var headline: String? { form.headline }

    /// The explanatory sentence as a key in the shared catalog.
    ///
    /// For the places that show only a text — they get the same interpretation as
    /// everywhere else, from the same table.
    public var message: String? { form.message }
}
