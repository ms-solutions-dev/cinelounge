import Core
import Diagnose
import Flows
import Foundation
import ParentalControls
import PlaylistKit
import ProfileKit

/// What is set up on this device — **and where it lives.**
///
/// **This is the actual subject of AP21.** Until here every credential came from the
/// environment (`CINELOUNGE_SERVER` and siblings), and that was not a stopgap but
/// a condition: the household's media server is not in the source code. From now on
/// it lives in the **Keychain** — where it belongs, and where the
/// TV app stores it too.
///
/// **Three stores, three reasons:**
///
/// * **Keychain** for access token and passwords (`SecureStore`, shared). It
///   does not survive a reinstall and should not — whoever deletes the app has deleted
///   it.
/// * **The playlist store** for channel lists (`PlaylistStore`), because it manages the credentials
///   anyway and puts them in the secret compartment.
/// * **The default store** for what is no secret: whether the portals are wanted.
///   A host name in the Keychain would be no protection but an inconvenience.
///
/// **Since 2026-09-21 this is the wrapper over the ``ProfileKit/ProfileBook``** (AP41,
/// row 6). The type keeps its name and is still asked at around forty places —
/// but "what is set up?" is now a question **to the active profile** and
/// no longer to the device. That is the whole reason AP41 came about: a
/// channel list hung on the device and applied to whoever sat in front of it; a child profile saw
/// the same 7,746 channels as an adult profile.
///
/// **The wrapper and not forty rewrites in one day.** The same reasoning as
/// over at ``ProfileKit/ProfileBook/accountState``: checking a model rebuild and a surface rebuild in one
/// step means afterwards not knowing which of the two broke something.
///
/// **Without a ledger the device applies.** Before the first adoption — and in the check run, which creates none —
/// the properties answer as before. An empty ledger means "not yet
/// adopted" and not "nothing set up"; whoever confuses the two takes the media library
/// away from a signed-in viewer.
@MainActor
public struct SetupState {

    private let keychain: SecureStore
    private let listen: PlaylistStore
    private let store: UserDefaults

    /// Where the ``ProfileKit/ProfileBook`` lives — the ``Core/FileStore``, as on the TV.
    private let ledgerStore: any KeyValueStore

    static let portalsKey = "setup.portalsWanted"
    static let doneKey = "setup.done"

    /// The old place of the bridge address, now only for adoption.
    ///
    /// **Since 2026-09-20 it lives where the TV stores it** (AP40): in the
    /// Keychain, via ``Core/BridgeAddress``. The same name stood here and there
    /// — only it meant two stores. And ``SecondScreen/Takeover`` writes a
    /// handed-over bridge **into the Keychain**: so it never arrived here, just like
    /// the age limit before the same correction.
    static let oldBridgeKey = "setup.portalBridge"

    public init(
        keychain: SecureStore = SecureStore(),
        listen: PlaylistStore? = nil,
        store: UserDefaults = .standard,
        ledgerStore: any KeyValueStore = FileStore()
    ) {
        self.keychain = keychain
        self.listen =
            listen ?? PlaylistStore(store: SecureStore(), secrets: SecureStore(), ledger: FileStore())
        self.store = store
        self.ledgerStore = ledgerStore
    }

    /// The profile currently in use — `nil` as long as there is none.
    ///
    /// **Read anew on every question and not remembered once.** The type is a `struct`
    /// that every view builds for itself; a remembered state would be exactly the intermediate copy
    /// that AP41 abolishes. A read costs about 15 µs according to the measurement of 2026-09-20.
    private var profile: Profile? { ProfileBook.read(from: ledgerStore).activeProfile }

    // MARK: - Lesen

    /// The media server, if the active profile owns one.
    ///
    /// **The access token stays the Keychain's**, and the profile only decides
    /// **whether** it applies: passwords do not belong in a file that every backup takes along
    /// (see ``ProfileKit/Access``). Whoever operates a profile without a media server gets `nil`
    /// — and with it the invitation to add one, instead of someone else's media library.
    ///
    /// **And only if it is *its* credential.** The comparison is over `server|user`:
    /// if the profile pointed to a different account than the signed-in session, the
    /// library of one person would stand under the name of another — the same error that
    /// ``ProfileKit/ProfileSwitch`` prevents by switching first the ledger and then the Keychain.
    /// Today the two cannot drift apart (``createProfiles(fallbackName:)`` makes the
    /// session the active profile); the check stands for the day there is a
    /// switching sheet.
    public var jellyfin: ServerCredentials? {
        guard let credential = try? keychain.loadCredentials() else { return nil }
        guard let profile else { return credential }
        let own = "\(credential.serverURL.absoluteString)|\(credential.userID)"
        return profile.jellyfin?.legacyAccountID == own ? credential : nil
    }

    /// The channel lists **of this profile**.
    ///
    /// **The finding AP41 is about.** A list hung on the device: it applied to
    /// whoever picked it up, and a child profile saw the same 7,746 channels as
    /// an adult profile. ``PlaylistKit/PlaylistStore`` still manages them — password in the
    /// secret compartment included —, but **whose** they are is stated in the profile.
    ///
    /// **Filtered and not stored separately.** Two profiles can have the same list;
    /// storing it twice would mean keeping two passwords for one credential and
    /// forgetting one of them when changing the other.
    public var channelLists: [Playlist] {
        guard let isAllowed = channelListWindow else { return listen.playlists }
        return listen.playlists.filter { isAllowed.contains($0.id) }
    }

    /// The identifiers of the channel lists **of this profile** — `nil` as long as there is no profile
    /// (then the device applies). The ``PlaylistKit/PlaylistStore/viewport`` of the sources.
    ///
    /// **The finding from the on-device test (build 1332, 2026-09-27, finding 3):** the overview counted
    /// via ``channelLists`` (per profile) and said "IPTV credentials: none", the list below it
    /// read the device catalog and showed `Y-IPTV`, active; Live, catalog and favorites played
    /// it. Now every place looks through the same window.
    ///
    /// **The same computation as on the TV** (``ProfileKit/ProfileBook/channelListWindow(available:)``).
    public var channelListWindow: Set<String>? {
        ProfileBook.read(from: ledgerStore).channelListWindow(available: listen.playlists.map(\.id))
    }

    /// Whether **this profile** wants the portals.
    public var portalsWanted: Bool {
        guard let profile else { return store.bool(forKey: Self.portalsKey) }
        return profile.wantsPortals
    }

    /// Where the bridge is — `nil` means: under its name on the home network.
    ///
    /// **The finding of 2026-09-06, reported as a requirement: Settings must have an area
    /// where the URL for portals can be maintained.**
    ///
    /// The screen said "There is nothing to set here, and that is intended" —
    /// **and this sentence lumped together two things that have nothing to do with each
    /// other:**
    ///
    /// * **Which portals exist** cannot be changed by the app. That is the answer to
    ///   an App Store rule and must not be weakened.
    /// * **Where the bridge is** is a machine of the viewer — just like the address
    ///   of the media server. There is no App Store reason for that, and without this field
    ///   the address was **hard-wired**: `PortalBridge.standard()` knows
    ///   `portals.example:8099`, and `CINELOUNGE_PORTALE` exists only in the simulator. On
    ///   a real phone the portals therefore worked **only** where
    ///   this one name resolves — and nowhere else.
    ///
    /// **`nil` and no entered default.** Whoever enters nothing should get the name from
    /// the agreement and not see it in the field: a prefilled
    /// address looks like one that somebody has checked.
    public var bridgeURL: URL? {
        BridgeAddress.load(from: keychain)
    }

    /// Whether the setup has been run through once.
    ///
    /// **Separate from "something is set up".** Whoever removes everything has still seen the
    /// setup; sending them through it again would mean assuming
    /// they do not know what they did. Settings lead back.
    public var done: Bool {
        store.bool(forKey: Self.doneKey)
    }

    /// Whether there is anything at all the app can do something with.
    public var hasContent: Bool {
        jellyfin != nil || !channelLists.isEmpty || portalsWanted
    }

    // MARK: - Schreiben

    /// Stores the media server — **in the account list and as the signed-in session.**
    ///
    /// **Both, because ``SecureStore`` keeps the two separately.** ``SecureStore/memorize(_:)``
    /// fills the list of all credentials, ``SecureStore/saveCredentials(_:)`` the one
    /// signed-in session; the shared test suite says it verbatim ("Saving alone
    /// does not fill the list", `Core/Tests/SecureStoreTests.swift`). Until 2026-09-06 the
    /// setup called only the second — the account list therefore stayed **always empty**
    /// in the release path, and the account switch had nothing to switch.
    ///
    /// **The list first.** If it fails, no session is signed in either that
    /// points to an entry that does not exist.
    /// **And at the active profile**, because since AP41: a credential comes into being where it is
    /// set up. If there is no ledger yet, the line does nothing — then
    /// ``createProfiles(fallbackName:)`` at the end of the setup creates one that already has it.
    public func create(jellyfin credential: ServerCredentials) {
        do {
            try keychain.memorize(credential)
            try keychain.saveCredentials(credential)
            ProfileAccesses.create(Access(credential), in: ledgerStore)
            Diagnose.step(.login, "Jellyfin server stored")
            Self.notify()
        } catch {
            Diagnose.error(.login, "Could not store the Jellyfin server: \(error)")
        }
    }

    public func create(channelList list: Playlist, password: String?) {
        listen.add(list, password: password)
        ProfileAccesses.create(.channelList(identifier: list.id), in: ledgerStore)
        Diagnose.step(.login, "Channel list stored")
        Self.notify()
    }

    /// **The old key is still written**, and not out of convenience: it is
    /// the source from which ``createProfiles(fallbackName:)`` takes over the preference as long as there is
    /// no ledger yet.
    ///
    /// **Without person, because this phone names none.** `X-CL-Profile` exists only on the
    /// TV; whoever operates here stands at the device attribute (``PortalKit/PortalDialect``).
    public func set(portals desired: Bool) {
        store.set(desired, forKey: Self.portalsKey)
        if desired {
            ProfileAccesses.create(.portals(person: nil), in: ledgerStore)
        } else {
            ProfileAccesses.removeAll(.portals, in: ledgerStore)
        }
        Self.notify()
    }

    /// Removes what disappears from the **device** — at every profile, not only at the
    /// active one.
    ///
    /// **The difference between "I don't want this anymore" and "this no longer
    /// exists".** A deleted channel list and a removed account are gone; leaving them in the
    /// other profiles would mean keeping pointers to nothing there. Whoever wants to take
    /// something away from a profile that continues to exist is at profile management
    /// and not here.
    public func remove(channelList identifier: String) {
        ProfileAccesses.removeEverywhere(.channelList(identifier: identifier), in: ledgerStore)
        Self.notify()
    }

    /// Removes a removed media server account from every profile.
    ///
    /// - Parameter kennung: `server|user`, as the old account list keeps it.
    public func remove(account identifier: String) {
        ProfileAccesses.removeMediaServer(identifier: identifier, in: ledgerStore)
        Self.notify()
    }

    // MARK: - Profile

    /// Turns what lies here into profiles — **once, and consequence-free afterwards.**
    ///
    /// **Called twice and effective once anyway:** at startup (``Startup``) and at the
    /// end of the setup. The second time is the difference between "the profile
    /// is created now" and "the profile is created at the next start" — ``ProfileAccesses``
    /// cannot store anything during setup yet, because there is no profile yet
    /// that anything could belong to.
    ///
    /// **The sequence itself has been in the shared ``Flows/ProfileStartup`` since AP58 R2** —
    /// the same as on the TV, with the steps ``Flows/ProfileStartup/Steps/phone``:
    /// without `ProfileStates` (the phone never wrote into the device base), **with**
    /// ``ProfileKit/StartChoice`` (without a switch on the phone there is no choice there, and the step
    /// does nothing) and with the same cleaner ``Flows/LegacyData`` (every step demands
    /// its proof). Here stands only what this phone knows: channel lists, portal preference,
    /// stores. **Since R2 the pointer** to the active profile follows too — at the end of the
    /// setup that means immediately and not only at the next start.
    ///
    /// - Parameter ersatzname: The name for a device without a media server user. It comes
    ///   from outside, because the language catalog lives in the program bundle and not here.
    @discardableResult
    public func createProfiles(fallbackName: String) -> Bool {
        ProfileStartup.fetch(
            .phone,
            device: ProfileStartup.DeviceState(
                channelLists: listen.playlists.map(\.id),
                wantsPortals: store.bool(forKey: Self.portalsKey),
                fallbackName: fallbackName),
            keychain: keychain, ledgerStore: ledgerStore, startStore: store,
            legacyStore: store)
    }

    /// **The setup has changed** — whoever builds tabs from it recomputes.
    ///
    /// **Finding of 2026-09-07, three screenshots:** channel list created in settings,
    /// bridge checked and found — and the app kept running as if only the media server
    /// were there: no Live tab, "No groups read yet", portals "off".
    /// `ShellModel.adopt` was called exactly once, at the end of the setup; every
    /// change after that stayed invisible until the next start. Now every write site
    /// here gives notice, and the shell listens.
    public static let changed = Notification.Name("SetupChanged")

    public static func notify() {
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// Enters the bridge address — `nil` takes it back.
    ///
    /// **Empty means back to the name and not "no portals".** Whoever empties the field
    /// wants the default, not the switch-off; there is the switch next to it for that.
    public func set(bridge address: URL?) {
        // **`save` takes the text and not the `URL`**, because it checks and
        // normalizes it itself — the same check as on the TV, instead of a second one here.
        BridgeAddress.save(address?.absoluteString ?? "", to: keychain)
    }

    /// Brings over a bridge address entered before 2026-09-20 — **once.**
    ///
    /// Only if nothing is in the Keychain: what is there was either written by this app
    /// or brought by a handoff, and both are newer.
    public func adoptBridgeAddress() {
        guard BridgeAddress.load(from: keychain) == nil,
            let old = store.string(forKey: Self.oldBridgeKey)
        else { return }

        BridgeAddress.save(old, to: keychain)
    }

    public func markDone() {
        store.set(true, forKey: Self.doneKey)
        Diagnose.step(.login, "Setup completed")
    }

    /// Clears everything — for the check and for "start over".
    ///
    /// **The profiles go with it.** If the ledger stayed, the next run would meet
    /// profiles with credentials that no longer exist — and ``ProfileBook/adopt`` would create
    /// no new ones, because something already stands there.
    public func clear() {
        try? keychain.clearCredentials()
        for list in listen.playlists { listen.remove(list.id) }
        store.removeObject(forKey: Self.portalsKey)
        store.removeObject(forKey: Self.oldBridgeKey)
        BridgeAddress.save("", to: keychain)
        store.removeObject(forKey: Self.doneKey)
        ProfileBook().write(in: ledgerStore)
    }
}
