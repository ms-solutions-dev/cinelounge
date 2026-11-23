import Combine
import Core
import Foundation
import ParentalControls
import PortalKit
import ProfileKit
import SwiftUI

#if os(tvOS)
    import TVServices
#endif

/// The shelf on the Apple TV Home Screen — **per profile and not per account** (AP52,
/// product decision 13 of 2026-09-25).
///
/// **The finding** (K2 of the counter-check of 2026-09-25): ``Core/TopShelfBridge`` hung
/// on the Jellyfin account. Two profiles on one account saw the same "Continue
/// Watching" there, so a child saw the adult's titles — as a picture, not as a path,
/// because a press on it already ran through the funnel ``MainView`` and was filtered.
///
/// **What the shelf shows now:**
///
/// * **The state of the active profile.** For the media server that is the state of its
///   account — Jellyfin keeps it itself (``Core/ContentSource/tracksStateItself``), and
///   the session follows the profile. The ``Core/StillLedger`` carries only providers and
///   portals, and those do not go onto the shelf: without a media server it stays empty.
/// * **Filtered by the profile's rule**, exactly like the Home screen: origin, age
///   limit, what was not understood (``ParentalControls/UnrecognizedLock/applicable(from:forItem:)``
///   via ``ParentalControlsState``). Filtering happens in the extension, via
///   ``Core/ShelfFilter`` — the reasoning is stated there.
///
/// **The rule is not rebuilt here**, but read from the same ``ParentalControlsState``
/// that the shell asks. A second calculation would drift apart at the next finding, and
/// the one left behind would be that of the Home Screen, because nobody looks at it
/// while testing.
public enum HomeShelf {

    /// Rewrites the shelf for the active profile and nudges the Home Screen.
    ///
    /// - Parameter credentials: The session as the caller currently knows it — `nil`
    ///   means: no media server, the shelf becomes empty.
    public static func write(credentials: ServerCredentials?) {
        let keychain = SecureStore()
        let context = context(
            credentials: credentials, state: ParentalControlsState(),
            profileStore: FileStore(), mode: TopShelfBridge.mode(),
            keychain: keychain, startChoice: StartChoice().identifier)
        TopShelfBridge.write(context)
        log(
            context, credentials: credentials, profileStore: FileStore(), keychain: keychain)
        reportChange()
    }

    /// **Why the shelf looks the way it does** — one line in the diagnostic log.
    ///
    /// **The finding (test Apple TV, 2026-09-28):** The shelf showed only the brand image,
    /// settings said "Continue Watching", and nowhere did it say why. Three paths lead to
    /// an empty shelf on purpose (PIN on the profile, auto-start as a different profile,
    /// nothing to show), a fourth by accident: the shared Keychain does not accept the
    /// state, so the extension reads nothing. That is why it is read back after writing.
    static func log(
        _ context: TopShelfContext?, credentials: ServerCredentials?,
        profileStore: any KeyValueStore, keychain: any KeyValueStore
    ) {
        guard let context else {
            let active = ProfileBook.read(from: profileStore).activeProfile
            let reason: String
            if let active, ProfilePIN(store: keychain, forItem: active.identifier).isSet {
                reason = "the profile has a PIN"
            } else if let choice = StartChoice().identifier, choice != active?.identifier,
                ProfileBook.read(from: profileStore).profile.contains(where: { $0.identifier == choice })
            {
                reason = "Auto-start applies to another profile"
            } else if active == nil {
                reason = "no active profile"
            } else {
                reason = "no Jellyfin and nothing started from IPTV"
            }
            report("Top Shelf: empty because \(reason)")
            return
        }
        let read = TopShelfBridge.load() == context
        report(
            """
            Top Shelf: \(context.mode.rawValue), Jellyfin \(context.jellyfin == nil ? "no" : "yes"), \
            \(context.extras?.count ?? 0) from IPTV and CL-Server, filter \(context.filter.applies ? "applies" : "open"), \
            \(read ? "read back" : "NOT readable back (shared Keychain)")
            """)
    }

    /// **Always in the report, but only when the line changes** (2026-09-29): Until then it
    /// went to `os.log` alone — an empty shelf on the TV (F-045) could not be explained
    /// from any report. The shelf is written on every load of the Home screen; without the
    /// comparison the report would be full of the same line.
    private static func report(_ row: String) {
        Diagnostics.network.info("\(row, privacy: .public)")
        guard row != lastLine else { return }
        lastLine = row
        Diagnostics.defect(row, since: nil, area: "Top Shelf")
        // And what the extension found last (``Core/TopShelfBridge/extensionFinding()``).
        Diagnostics.defect(
            "Top Shelf, extension last: \(TopShelfBridge.extensionFinding() ?? "never reported")",
            since: nil, area: "Top Shelf")
    }

    private static var lastLine: String?

    /// Writes the shelf with the session from the Keychain — the path of the shell, which
    /// does not have the session in hand.
    public static func writeFromSession() {
        write(credentials: try? SecureStore().loadCredentials())
    }

    /// The state for the extension — **the connection that the tests can grip.**
    ///
    /// **Empty as soon as the shelf could show someone what lies behind a door** (check
    /// 2026-09-25, finding 5; coordinator's decision). The Home Screen shows the shelf
    /// **before** any question — whoever holds the remote sees it, even if the app is about
    /// to show "Who's watching?" or the number pad. It therefore stays empty if
    ///
    /// * the active profile carries a **profile PIN** — the app would demand it, the Home
    ///   Screen showed its titles without it; or
    /// * the **start choice** points to a different profile — the device then starts as
    ///   someone else, and the shelf would show the history of a person who is not about to
    ///   sit in front of it (typical: a child's-room TV on which an adult watched in the
    ///   evening).
    ///
    /// **Empty and not the filter of the start profile:** The shelf hangs on the account of
    /// the active profile; with another's filter it would be one person's history under
    /// the other's rule — when in doubt, empty. Without a start choice the app asks at
    /// startup anyway, and a profile without a PIN can be chosen there by anyone; the
    /// shelf then reveals nothing that is not one press away.
    ///
    /// - Parameters:
    ///   - stand: The parental controls, freshly read.
    ///   - profilablage: Where the profile book lives; the active profile comes from it.
    ///   - schluesselbund: Where the profile PINs live.
    ///   - startwahl: As whom the device starts (``ProfileKit/StartChoice``), `nil` for "ask".
    static func context(
        credentials: ServerCredentials?, state: ParentalControlsState,
        profileStore: any KeyValueStore, mode: TopShelfMode,
        keychain: any KeyValueStore, startChoice: Profile.Identifier?
    ) -> TopShelfContext? {
        let active = ProfileBook.read(from: profileStore).activeProfile
        if let active, ProfilePIN(store: keychain, forItem: active.identifier).isSet {
            return nil
        }
        // **Only a profile that exists** (2026-09-29): After merges, "Start automatically"
        // could point to a vanished identifier — the shelf then stayed empty in every
        // presentation, although nobody else was meant.
        if let startChoice, startChoice != active?.identifier,
            ProfileBook.read(from: profileStore).profile.contains(where: { $0.identifier == startChoice })
        {
            return nil
        }
        let rule = state.rule
        let filter = ShelfFilter(rule: rule, childMode: rule.scope.isInChildMode)
        return TopShelfBridge.context(
            credentials: credentials, profile: active?.identifier.rawValue, filter: filter, mode: mode,
            extras: extras(
                forItem: active, filter: filter, mode: mode, store: profileStore,
                clServer: clServerContribution(forItem: active), row: row(forItem: active)))
    }

    /// What IPTV and CL-Server contribute to the shelf — **from the profile's state**
    /// (product decision, 2026-09-28: "like Netflix, the profile's last-watched content").
    ///
    /// **Nothing, as soon as a rule applies.** These titles carry no age rating, and the
    /// shelf stands on the Home Screen before any question; ``ShelfFilter`` would have
    /// nothing to check on them. As with the PIN above: when in doubt, empty.
    static func extras(
        forItem profile: Profile?, filter: ShelfFilter, mode: TopShelfMode, store: any KeyValueStore,
        clServer: [TopShelfEntry] = [], row: [TopShelfEntry]? = nil
    ) -> [TopShelfEntry] {
        guard let profile, !filter.applies else { return [] }
        // **If the Home screen's row is in place, exactly it applies** — the same titles in
        // the same order, channels included. The path below it is the fallback until it is
        // in place: after startup, before the Home screen has loaded.
        if mode == .resume, let row { return row }
        let state = StillLedger.read(from: store, forItem: profile.identifier.rawValue).state
        let iptv = TopShelfEntry.from(state, mode: mode)
        guard !clServer.isEmpty else { return iptv }
        // Favorites have no common point in time: first IPTV, then the CL-Server.
        if mode == .favorites { return Array((iptv + clServer).prefix(8)) }
        // **By "last watched", wherever from** — without a timestamp at the back.
        let mixed = (iptv + clServer).sorted {
            ($0.recent ?? .distantPast) > ($1.recent ?? .distantPast)
        }
        return Array(mixed.prefix(8))
    }

    /// What the CL-Server contributes to the shelf — **per profile**, last fetched by
    /// ``fetchCLServer(from:)``.
    ///
    /// **In memory and not in a store:** The shelf is written only while the app runs, and
    /// at the next start the shell fetches the state anew anyway. If it belongs to a
    /// different profile than the active one, it does not count.
    private static var clServer: (profile: String, mode: TopShelfMode, entries: [TopShelfEntry])?

    /// Fetches "Continue Watching" from the CL-Server and rewrites the shelf (2026-09-28).
    ///
    /// **Without a source the contribution is empty** — a profile without a CL-Server has
    /// none, and that of a previous profile must not remain. A portal in its own section
    /// (``Core/PortalPreferences``) stays outside here too.
    public static func fetchCLServer(from source: PortalSource?) async {
        guard let source, let profile = ProfilePointer.active else {
            clServer = nil
            writeFromSession()
            return
        }
        let preferences = PortalPreferences.load(from: SecureStore())
        let mode = TopShelfBridge.mode()
        let entries = ((try? await source.shelfContributions(mode: mode)) ?? [])
            .filter { preferences.accepts(identifier: $0.id) }
        clServer = (profile, mode, entries)
        writeFromSession()
    }

    /// "Continue Watching" as the Home screen shows it — **per profile** (2026-09-28).
    private static var row: (profile: String, entries: [TopShelfEntry])?

    /// Takes over the Home screen's row and rewrites the shelf — **only if it has
    /// changed**: the Home screen rebuilds itself several times while scrolling, and every
    /// message to tvOS makes the Home Screen refetch the shelf.
    public static func adopt(continueWatching entries: [TopShelfEntry]) {
        guard let profile = ProfilePointer.active else { return }
        if let row, row.profile == profile, row.entries == entries { return }
        row = (profile, entries)
        writeFromSession()
    }

    /// The Home screen's row for this profile — `nil` while it is not yet in place or
    /// belongs to another.
    static func row(forItem profile: Profile?) -> [TopShelfEntry]? {
        guard let row, row.profile == profile?.identifier.rawValue else { return nil }
        return row.entries
    }

    /// The CL contribution of the active profile — empty if it belongs to another.
    static func clServerContribution(forItem profile: Profile?) -> [TopShelfEntry] {
        // Fetched for a different presentation (Continue Watching instead of favorites) does
        // not count.
        guard let clServer, clServer.profile == profile?.identifier.rawValue,
            clServer.mode == TopShelfBridge.mode()
        else { return [] }
        return clServer.entries
    }

    /// Tells tvOS that the shelf has to be fetched again.
    ///
    /// **Without the nudge the Home Screen would hold on to the old shelf** — with the
    /// images of the previous profile, until tvOS asks again by itself. The setting
    /// claimed so far that no such path exists; it has existed since tvOS 13.
    static func reportChange() {
        #if os(tvOS)
            TVTopShelfContentProvider.topShelfContentDidChange()
        #endif
    }
}

/// Rewrites the shelf **as soon as the ``ChildGuard/RuleState`` changes** — on a
/// profile switch, on a rule change — and on every message from remote
/// (``Core/ProfilePointer/switched``, ``ProfileKit/ProfileCloud/arrived``).
///
/// **A modifier of its own** for the same reason as ``ChildGuard``: the body of the
/// shell is at the limit of the compiler's computation budget.
///
/// **The message from remote writes in addition**, although it usually also changes the
/// rule state: A relocation can put the session onto a different account without
/// anything changing in the rule — then the shelf would stay with the previous
/// account.
///
/// **And on going to the background** (check 2026-09-25, finding 4): That is the moment
/// at which the Home Screen shows the shelf — whatever was changed in the state until
/// then without a guard seeing it arrives here at the latest.
struct ShelfGuard: ViewModifier {

    let state: ChildGuard.RuleState
    /// The CL-Server source of the active profile — its "Continue Watching" belongs on the
    /// shelf.
    var portals: PortalSource?
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onAppear { HomeShelf.writeFromSession() }
            .onChange(of: state) { _, _ in HomeShelf.writeFromSession() }
            .onReceive(ChildGuard.fromRemote) { _ in HomeShelf.writeFromSession() }
            // **Fetched anew when the source changes** — at startup and on every profile switch —
            // and when leaving the app: Then tvOS shows the shelf, and what was just watched
            // should be at the front.
            .task(id: portals.map(ObjectIdentifier.init)) {
                await HomeShelf.fetchCLServer(from: portals)
            }
            .onChange(of: scenePhase) { _, fresh in
                if fresh == .inactive { Task { await HomeShelf.fetchCLServer(from: portals) } }
                if fresh == .background { HomeShelf.writeFromSession() }
            }
    }
}

/// Rewrites the shelf **as soon as the settings change something about it** (check
/// 2026-09-25, finding 4).
///
/// The settings keep their own ``ParentalControlsState`` and their own
/// ``ProfileModel``; ``ShelfGuard`` on the shell sees their changes only when one
/// leaves the settings and the shell rereads. Until then — or until the app was left
/// entirely — the Home Screen showed the shelf under the old rule: a new limit, a new
/// PIN, a deleted or switched profile did not arrive there.
///
/// **On the state's rule and on every change of the profile model.** The rule reports
/// limit, PIN, device lock, what was not understood and allow list; the profile model
/// reports switch, removal and the profile PIN
/// (``HomeShelf/context(credentials:state:profileStore:mode:keychain:startChoice:)``).
/// Reading happens after the change — `objectWillChange` comes before it, which is why
/// it happens only in the next run of the main loop.
struct ShelfCatchUp: ViewModifier {

    let lock: ParentalControlsState
    var profile: ProfileModel?

    func body(content: Content) -> some View {
        content
            .onReceive(lock.$rule.removeDuplicates().dropFirst()) { _ in
                HomeShelf.writeFromSession()
            }
            .onReceive(Self.changes(from: profile)) { _ in HomeShelf.writeFromSession() }
    }

    /// The changes of the profile model, delivered after the change.
    private static func changes(from profile: ProfileModel?) -> AnyPublisher<Void, Never> {
        guard let profile else { return Empty().eraseToAnyPublisher() }
        return profile.objectWillChange
            .receive(on: RunLoop.main)
            .eraseToAnyPublisher()
    }
}
