import Core
import DesignSystem
import Features
import Flows
import JellyfinKit
import ProfileKit
import SwiftUI

/// The app's signpost: What is set up decides what is shown.
///
/// There are two mutually independent accounts — a media server and a channel
/// list —, and **each suffices on its own**. Four states follow from that, and
/// the calculation for them lives not here but in ``AccountState``: It must also be
/// available to the views in `Features` that depend on it (the Library
/// pill, the Live area in the sidebar), and two versions of the same condition
/// drifted apart at the first retrofit.
///
/// **The accounts do not live here, they are derived and passed in.**
/// The server account lives in the Keychain, the channel lists live in their own
/// store, and both belong to other building blocks. If this view read them
/// itself, there would be a second version of the catalog, and an account deleted in the
/// settings would still be present here.
struct RootView: View {

    /// The account for the media server, if one is stored.
    let credentials: ServerCredentials?

    /// Whether the portals are switched on. See ``AccountState/hasPortals``.
    let hasPortals: Bool

    /// Whether at least one channel list is stored.
    ///
    /// `nil` means **not yet known** — the list store has not been
    /// read yet. Then what stands in the ``ProfileKit/ProfileBook`` applies, so that the
    /// setup does not appear for a moment although a list has long been
    /// entered. As soon as the truth is available, it applies.
    let hasPlaylist: Bool?

    /// The same device ID as at sign-in — the server recognizes the
    /// TV by it.
    let deviceID: String

    let onSignedIn: (ServerCredentials) -> Void

    /// Accepts an entered channel list and checks it; see
    /// ``PlaylistLoginView/onSubmit``.
    let onPlaylistEntered: @MainActor (PlaylistAccess) async -> String?

    let onSignOut: () -> Void

    /// After an account switch from the settings.
    ///
    /// **Without a default value**, like ``SettingsView/liveGroups``: A `= { _ in }` here would have
    /// the same effect as there — the switch would rewrite the Keychain, the app
    /// would keep showing the old account, and nothing would be broken enough to be noticed.
    let onAccountSwitched: (ServerCredentials?) -> Void

    @EnvironmentObject private var language: LanguageStore
    @EnvironmentObject private var themes: ThemeStore

    /// Where the user currently is. `nil` means "nowhere yet" — then the
    /// start from ``AccountState/landing`` applies.
    ///
    /// This marker is the reason a removed account does not end on an
    /// empty screen: When the place falls away, ``AccountState/landing(from:)`` moves
    /// it on to the one that still holds.
    @State private var area: AccountState.Area?

    /// A source being added from the settings — **on the sheets of the first setup**
    /// (``SetupShell/retrofit(_:onSignedIn:onSwitched:)``), ended with its sheet. `nil` if nothing
    /// is being retrofitted.
    @State private var retrofit: SetupJourney?

    /// The first setup while it runs (AP88) — **begun when ``SetupShell`` reads the gate as open**,
    /// ended when the machine reaches `finished`.
    ///
    /// **It stands before every other place**, ``AccountState/landing`` included: the setup makes
    /// a profile active and stores its sources one by one, and every one of those changes moves
    /// the landing. Following it would leave the setup after the first source and before A7.
    @State private var journey: SetupJourney?

    /// Holds back the rebuild after a language switch as long as a movie is playing or a
    /// sheet is open — see ``Features/LanguageDeferral`` (final check 2026-09-25, B-1).
    @State private var languageDeferral = LanguageDeferral()

    /// The intermediate copy from the store, read **once per program run**.
    ///
    /// As a `static let` and not as a field: A Keychain access is not
    /// a field access, and `body` runs again with every focus movement. As an
    /// ordinary property this would have become one Keychain access per
    /// frame.
    private static let cached = ProfileBook.read(from: FileStore()).accountState

    /// The source **once per account**, not once per render.
    ///
    /// **Here a new one was built at every evaluation of `body`, and that was
    /// more expensive than it looks.** Every ``JellyfinSource`` brings along its own
    /// `URLSession` with its own connection pool, and a session with a delegate
    /// is held by the system until it is explicitly ended — which never happened here.
    /// `body`, however, runs with every focus movement, every language
    /// change and every color scheme change.
    ///
    /// The consequence was dozens of open connections to the same server, none of which
    /// was used any more. That is not merely untidy: tvOS releases sockets when
    /// the app goes to the background but keeps remembering them — and the more of them
    /// sit in the pool, the greater the chance that a request lands on a dead one
    /// and waits until the timeout. Exactly that was in the diagnostic report.
    ///
    /// `static` and not `@State`: When the color scheme changes, this view is
    /// rebuilt completely via a new identity (see `CineLoungeApp`), and
    /// a `@State` would be lost in the process — the session would be a new one again.
    private static let sources = SourceCache()

    static func source(for credentials: ServerCredentials, deviceID: String) -> JellyfinSource {
        sources.source(for: credentials, deviceID: deviceID)
    }

    private let store = SecureStore()

    /// The derived state. The truth beats the intermediate copy.
    private var account: AccountState {
        AccountState(
            hasJellyfin: credentials != nil,
            hasPlaylist: hasPlaylist ?? Self.cached.hasPlaylist,
            hasPortals: hasPortals
        )
    }

    /// **A language switch rebuilds the main view** (AP46, 2026-09-25) — the `.id` on
    /// ``MainView``. `String(localized:)` reads from ``Core/AppLanguageSetting/bundles`` at build time,
    /// and SwiftUI does not notice its change; the same situation as with the color scheme at the
    /// root. Since the language travels with the profile, it also changes without anyone
    /// standing in the settings. **Here and not at the root:** The setup
    /// before it carries typed fields, and a language switch there would tear them away.
    ///
    /// **And not while something is presented** (final check 2026-09-25, B-1):
    /// The identity tore down the player and the handoff from the iPhone. It now comes from
    /// ``Features/LanguageDeferral``; if a movie is playing or a sheet is open, it
    /// checks until it is closed, and only then rebuilds.
    var body: some View {
        content
            .environment(\.accentPalette, .brand)
            .onAppear {
                settle()
                // The key source beneath the focus engine — rationale at
                // ``RemoteKeyTrace``. Here and not in the app init, because the
                // observer is meant to live on the main actor.
                RemoteKeyTrace.start()
                // The version marker into both traces: From here on the lines
                // belong to THIS build — rationale at ``Diagnostics/noteLaunch()``.
                Diagnostics.noteLaunch()
            }
            // Catches both directions: retrofitting as well as removing. As one
            // place and not as a callback at every spot that changes something — otherwise
            // one of them forgets the redirect, and the rarer one at that: removal.
            .onChange(of: account) { _, _ in settle() }
            .onChange(of: journey?.state) { _, state in
                if case .finished = state { endSetup() }
            }
            .onChange(of: retrofit?.state) { _, state in
                if case .finished = state { endRetrofit() }
            }
            .onChange(of: language.current) { old, _ in
                languageDeferral.switchObserver(from: old.rawValue, isBlocked: PresentationState.pending)
            }
            // **Check while something is waiting** — once per second. Nobody reports the closing of a
            // sheet at a spot that applies to all sheets; rebuilding
            // a second after the end credits goes unnoticed.
            .task(id: languageDeferral.waiting) {
                while languageDeferral.waiting, !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    languageDeferral.verify(isBlocked: PresentationState.pending)
                }
            }
    }

    /// Brings place and store into agreement with the derived state.
    private func settle() {
        beginSetupIfOpen()
        let next = account.landing(from: area ?? account.landing)
        if area != next { area = next }

        // **Until 2026-09-21 the updating of the intermediate copy stood here** (AP41).
        // ``AccountState`` was written back into the Keychain at every deviation,
        // so that the next start knows what is set up. That
        // goes away: The accounts live in the ``ProfileKit/ProfileBook``, and they come into being
        // where they are set up — at sign-in, when accepting a
        // channel list, when switching on the portals. **A copy that someone has to keep updating
        // is a second truth with a delay** — and this one only the
        // device knew, never the person.
    }

    /// Starts the first setup when the gate is open — **at the cold start the gate read in the
    /// app's `init`** (``SetupShell/prepare()``), later only when nothing is set up any more
    /// (after "Reset everything").
    private func beginSetupIfOpen() {
        guard journey == nil, retrofit == nil else { return }
        if let running = SetupShell.running {
            journey = running
            return
        }
        let start = SetupShell.takeLaunchStart() ?? (account.landing == .setup ? SetupShell.start() : nil)
        guard let start else { return }
        journey = SetupShell.begin(
            start, onSignedIn: onSignedIn, onSwitched: onAccountSwitched,
            onTheme: { [themes] in themes.choose($0) })
    }

    private func endSetup() {
        guard let journey else { return }
        SetupShell.finish(journey)
        self.journey = nil
        settle()
    }

    /// Opens the sheet of a source for the active profile — Jellyfin from "Add access".
    private func beginRetrofit(_ kind: Access.Kind) {
        guard retrofit == nil else { return }
        retrofit = SetupShell.retrofit(kind, onSignedIn: onSignedIn, onSwitched: onAccountSwitched)
    }

    private func endRetrofit() {
        guard let retrofit else { return }
        SetupShell.finishRetrofit(retrofit)
        self.retrofit = nil
        settle()
    }

    // MARK: - Was zu sehen ist

    @ViewBuilder
    private var content: some View {
        if let journey {
            SetupView(
                journey: journey, languages: language, cloud: CloudStartup.cloud,
                describe: SetupShell.describe, acceptChannelList: onPlaylistEntered)
        } else if let retrofit {
            // **Retrofitting takes the sheets of the first setup** (AP88 wave 5) — the same flow,
            // the same explanations; a second, shorter path for "just the other one as well"
            // would be a second place with the same errors.
            SetupView(
                journey: retrofit, languages: language, cloud: CloudStartup.cloud,
                describe: SetupShell.describe, acceptChannelList: onPlaylistEntered)
        } else {
            // **One area, one shell** (AP29, 2026-09-11).
            //
            // Here there were three branches: the shell for the media server and two
            // signposts for "channel list only" and "portals only". The two were
            // dead ends — a sentence, a button "Add server", the language choice. **Anyone who
            // stood there reached no setting**, because those hang off the
            // sidebar, and that existed only with a media server. An app the
            // remote does not lead out of.
            //
            // ``MainView`` now manages without: The Library row drops out, everything
            // else stays — Live, Sports, Portals, Favorites, Search, Settings.
            //
            // **No setup without the gate** (AP88): the landing `.setup` without an open
            // ``Flows/SetupGate`` means a profile here can still play — "Who is watching?" in the
            // shell asks for it (G10), and the old sign-in screen is gone.
            MainView(
                source: credentials.map { Self.source(for: $0, deviceID: deviceID) },
                credentials: credentials,
                languages: language,
                onSignOut: onSignOut,
                onAccountSwitched: onAccountSwitched,
                // A further account takes the same path as retrofitting
                // a source: via ``retrofit`` onto the setup's Jellyfin sheet.
                onAddAccount: { beginRetrofit(.jellyfin) },
                start: area ?? account.landing
            )
            .id(languageDeferral.identifier(current: language.current.rawValue))
        }
    }
}

/// Holds the connection to the media server across the lifetime of the UI.
///
/// **The reason is not taste but a measured cause of failure.** The source
/// was created in the body of ``RootView``, that is, anew at every evaluation — and `body`
/// runs with every focus movement, every language change and every change of the
/// color scheme. Every ``JellyfinSource`` brings along its own `URLSession` with its own
/// connection pool; a session with a delegate is held by the system until it is
/// explicitly ended. That never happened.
///
/// As a result dozens of unused connections to the same server stood open. That is
/// not merely untidy: tvOS releases network connections when an app goes to the
/// background, but keeps remembering the socket. The more of them sit in the pool,
/// the greater the probability that a request lands on a dead one
/// and waits until the timeout — which appeared in the device's diagnostic report as a
/// "timeout" against a server that answers from another computer in
/// fifty milliseconds.
///
/// The key is the **account**, not the point in time: If someone signs out and signs in again with
/// a different account, that calls for a new source. The old one is ended
/// properly in the process instead of lying around.
final class SourceCache: @unchecked Sendable {

    private let lock = NSLock()
    private var key: String?
    private var current: JellyfinSource?

    func source(for credentials: ServerCredentials, deviceID: String) -> JellyfinSource {
        // The account as a whole, not just the host name: A change of
        // user on the same server also needs a connection of its own, otherwise it would
        // continue running with the previous account's key.
        let wanted = "\(credentials.serverURL.absoluteString)|\(credentials.userID)|\(deviceID)"

        lock.lock()
        defer { lock.unlock() }

        if key == wanted, let current { return current }

        // Explicitly end the previous one. Without that it would remain, together with its connection pool —
        // exactly the state this class exists to prevent.
        if let current { Task { await current.close() } }

        let source = JellyfinSource(credentials: credentials, deviceID: deviceID)
        key = wanted
        self.current = source
        return source
    }
}
