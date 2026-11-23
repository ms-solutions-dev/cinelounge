import CloudSync
import Core
import Foundation

/// The sync between the books on the device and the zones in iCloud.
///
/// **The books stay the truth for the UI** (AP43): ``ProfileBook`` and
/// ``Core/StillLedger`` are read and written as before, synchronously and without a network.
/// CloudKit is the **place of sync**, not the source — whoever reverses that has an app
/// that knows nothing without a network.
///
/// The path is the same circle in both directions:
///
/// ```
/// Buch  ──hinauf──▶  Spiegel  ──gleicheAb──▶  Server
/// Buch  ◀─herunter──  Spiegel  ◀─gleicheAb───  Server
/// ```
///
/// **``upload(_:)`` writes the difference, not the state**, and that is not mere
/// thrift: ``CloudSync/ProfileZone/write(_:now:)`` queues every record and resets
/// `changed`. If every pass wrote the whole book, the device that merely **repeats**
/// would win against the one that actually changed something — the rule
/// "the younger writer wins" would run empty, and nobody would see it.
///
/// **One zone per profile.** It is named after the profile ID (``ProfileMapping/zone(forItem:owner:)``)
/// and not after the name: whoever renames their profile keeps their state.
@MainActor
public final class ProfileCloud {

    public let hub: CloudHub
    /// Readable within the module for ``ProfileCloud/cleanUpAfterDeletion(_:)`` (separate file).
    let store: any KeyValueStore
    private let mirrorFolder: URL?
    private var zones: [Profile.Identifier: ProfileZone] = [:]
    private var observations: [Profile.Identifier: [ObservationResult]] = [:]

    /// Zones that are currently running a sync pass.
    ///
    /// **While one is running, observation stays silent.** A pass fetches first and
    /// writes only afterwards; whoever calls ``download(_:)`` in the middle writes a
    /// **half** mirror into the book — on first contact that is the state of the cloud
    /// without everything this device knows, and the local state is gone before it
    /// could go up. At the end of the pass ``reconcile(_:now:)`` writes by itself.
    private var inProgress: Set<Profile.Identifier> = []

    /// The household's zone — see ``household()``.
    private var householdZone: ProfileZone?
    private var householdWatch: ObservationResult?

    /// The brake — see ``SyncCadence``.
    public let cadence = SyncCadence()

    /// Called when something arrived from remote and was written into the books.
    ///
    /// **A callback and not an `@Observable` field**, because there is nothing to observe here:
    /// the truth for the UI is the books, not this object. Whoever draws reads them anew —
    /// this call only says that it is worth doing now.
    public var arrival: (@MainActor () -> Void)?

    /// Posted whenever ``arrival`` is called (final review 2026-09-25,
    /// C2-5).
    ///
    /// **The finding:** ``arrival`` was not hooked up anywhere. A move note from remote
    /// that puts the active profile into another one switched the book, but the UI and
    /// parental controls only at the next occasion — a child sat for a while under the
    /// rules of the profile that no longer existed. **A notification instead of one more
    /// callback**, because those who need to listen (the child guard of the shell) live deep
    /// in the UI and do not know this holder; and a callback has exactly one
    /// slot, which the next hookup would overwrite.
    public static let arrived = Notification.Name("Profilwolke.angekommen")

    /// Calls ``arrival`` and posts ``arrived``.
    func notify() {
        arrival?()
        NotificationCenter.default.post(name: Self.arrived, object: nil)
    }

    /// This device's channel lists — **handed in from outside.**
    ///
    /// ``ProfileKit`` does not know `PlaylistKit` and should not; the app's shell
    /// knows where the lists live and converts them.
    ///
    /// **Without this hookup the sync does not touch the channel lists** — it
    /// writes none up and, more importantly, **deletes none**. An app that does not
    /// manage the lists (an extension, a preview) would otherwise clear all of the viewer's lists
    /// out of the cloud on its first pass because it knows none.
    public var channelLists: (@MainActor () -> [ChannelListAccess])?

    /// The channel lists that arrived from the cloud.
    public var adoptsChannelLists: (@MainActor ([ChannelListAccess]) -> Void)?

    /// Where the playback preferences live — **handed in from outside**, like
    /// ``channelLists``.
    ///
    /// The **device's** store (in the app, the Keychain); the per-person slot is
    /// computed by ``Core/ProfileStore`` itself. Not ``store``, because the preferences have
    /// always lived in the Keychain and the books in files — a move just for the
    /// sync would mean the player and the cloud read different places.
    ///
    /// **Without this hookup no preferences go up and none come down** — and none
    /// is deleted either: their type is not among the cleared ones (see
    /// ``PreferenceMapping``). An app that does not manage them leaves the other
    /// device's choice alone.
    public var preferenceStore: (any KeyValueStore)?

    /// Which preferences last matched the cloud — per profile and key.
    ///
    /// **The protection against the race between writing and fetching down**
    /// (cross-check of 2026-09-24). A pass uploads and, after an `await`, fetches
    /// down; if the person writes in between — and the window sits right behind the
    /// profile switch — the cloud still held the old value, and ``download(_:)``
    /// wrote it over the new one. The next pass saw no difference anymore, the choice
    /// was silently gone. Every silent push between a write and the next pass did the same.
    ///
    /// **Therefore only what changed in the cloud is adopted** — measured against
    /// this state. If what was last synced is still there, the local value is
    /// the younger one and stays. **In memory only:** after a restart it is empty,
    /// and then the cloud wins — the same rule as on first contact.
    private var preferenceState: [Profile.Identifier: [String: String]] = [:]

    /// The same for a profile's files (``DocumentPreference``): what last went up or
    /// down — only what changed up there since then is adopted.
    private var documentState: [Profile.Identifier: [String: String]] = [:]

    /// Where the person tokens live (AP47) — **handed in from outside**, like
    /// ``preferenceStore``: in the app the Keychain; the per-profile slot is computed by
    /// ``PortalMarkerSlot``.
    ///
    /// **Without this hookup no token goes up and none comes down** — and none is
    /// deleted either: ``PortalMarkerMapping/contentType`` is not among the cleared
    /// types. The iPhone does not manage it today and leaves the TV's token alone.
    public var brandStore: (any KeyValueStore)?

    /// Connects the Keychain — **preferences and person tokens in one go.**
    ///
    /// **The finding of the cross-check of 2026-09-24:** The app set ``preferenceStore`` and
    /// forgot ``brandStore``. All checks were green because they set the store by hand —
    /// and in the app the token never went up and never came down. Both slots
    /// live in the same Keychain; one call for both lets neither be forgotten.
    /// `FeaturesTests/PortalmarkeVerdrahtung` checks that `CloudStartup` takes exactly this path.
    public func attachKeychain(_ keychain: any KeyValueStore) {
        preferenceStore = keychain
        brandStore = keychain
    }

    /// Which token last matched the cloud — as a digest, per profile.
    ///
    /// **The same protection as ``preferenceState``, and here it weighs more.** A pass uploads
    /// and, after an `await`, fetches down; if a share arrived in between and
    /// stored a new token, the old one was still up there, and ``download(_:)`` wrote it
    /// over the new one. Therefore only what changed in the cloud since the last
    /// sync is adopted. **A digest and not the token**, so the secret does not
    /// sit in memory one more time. Empty after a restart — then the cloud wins.
    private var brandState: [Profile.Identifier: String] = [:]

    /// Where PIN, age limit, parental controls, preferences and person token live **when an
    /// ID moves** (cross-check strand C, finding 5).
    ///
    /// **A connection of its own, separate from ``brandStore`` and ``preferenceStore``.** Until
    /// C2 the move ran via ``brandStore`` — and only whoever syncs the person token sets that.
    /// The iPhone does not; there, on first iCloud contact, the state moved,
    /// and PIN, age limit and preferences stayed behind under the dead ID. An
    /// app can fail to sync the token and still manage a PIN; those are two
    /// questions, and each gets its own connection.
    public let moveBundle: (any KeyValueStore)?

    /// - Parameters:
    ///   - ablage: where ``ProfileBook`` and ``Core/StillLedger`` live.
    ///   - umzugsbund: **no default, on purpose** — see ``moveBundle``. Whoever passes `nil`
    ///     says explicitly: this app manages no PIN and no preferences.
    ///   - spiegelordner: where the zone mirrors live; `nil` keeps them in memory only
    ///     (checks, previews).
    ///   - selbsttaetig: whether a change triggers a pass to the server by itself. The
    ///     checks call ``reconcile()`` themselves so that nothing runs on the side.
    public init(
        hub: CloudHub, store: any KeyValueStore,
        moveBundle: (any KeyValueStore)?, mirrorFolder: URL? = nil,
        automatic: Bool = true
    ) {
        self.hub = hub
        self.store = store
        self.moveBundle = moveBundle
        self.mirrorFolder = mirrorFolder
        self.automatic = automatic
    }

    private let automatic: Bool

    /// The one cloud of this app run — **so that the UI can find it.**
    ///
    /// **The same design as ``SyncCall`` and for the same reason.** It is built
    /// in the shell (`CloudStartup`) and needed in the settings; in between
    /// lie `Features` and `FeaturesPhone`, which cannot see the shell. Passing it through eight
    /// views would mean changing eight places as soon as a ninth needs it — and
    /// building a cloud in every preview that nobody wants there.
    ///
    /// **`nil` is a valid state** and means "without cloud": the preview, a
    /// check run, an app without the CloudKit entitlement. The screens that
    /// need it say so then — they do not stall.
    public static var attached: ProfileCloud?

    // MARK: - Zonen

    /// A profile's zone — built on first use, given its rules and
    /// registered with the hub so that a silent push reaches it.
    @discardableResult
    public func zone(forItem identifier: Profile.Identifier) -> ProfileZone? {
        if let available = zones[identifier] { return available }
        guard let marker = ProfileMapping.zone(forItem: identifier) else { return nil }
        let zone = ProfileZone(
            file: mirrorFolder?.appending(path: "wolke-\(identifier.rawValue).json"),
            service: hub.service, zone: marker, automatic: automatic)
        zone.rule(forItem: StillMapping.stillType, StillMapping.stillRule)
        zone.rule(forItem: ProfilePINMapping.contentType, ProfilePINMapping.rule)
        zone.rule(forItem: PreferenceMapping.contentType, DocumentPreference.rule)
        // **A deleted zone takes the profile along on the device** (2026-09-27) — see
        // ``zoneRemoved(_:_:)``.
        zone.onRemoval = { [weak self] reason in self?.zoneRemoved(identifier, reason) }
        zones[identifier] = zone
        hub.register(zone)
        // **What comes from remote lands in the book without further action.** Otherwise every place
        // that triggers a pass would have to call ``download(_:)`` afterwards — and the one that
        // forgets is the one where the state does not arrive. The silent push goes
        // through ``CloudSync/CloudHub`` and through nobody's call list.
        observations[identifier] = Self.readTypes.map { contentType in
            zone.observe(contentType) { [weak self] _ in
                guard let self, !self.inProgress.contains(identifier) else { return }
                guard self.download(identifier) else { return }
                self.notify()
            }
        }
        return zone
    }

    /// Whether a change to the profile may go into the mirror **now**.
    ///
    /// **Always after first contact.** Before that only if the mirror already carries records:
    /// this device wrote those, since nothing has come from the server yet — so
    /// continuing to write flattens nobody's state. If it is empty, the old rule applies:
    /// fetch first, then talk (``reconcile(_:now:)``).
    ///
    /// **The finding (on-device test 2026-09-27):** In the simulator without iCloud no zone ever
    /// reached the server. The rename therefore stayed only in the book; when later
    /// the portal person wrote a record, ``download(_:)`` played the old name back from the
    /// mirror. "Changing the name is not applied."
    public func mayPassOn(_ identifier: Profile.Identifier) -> Bool {
        guard let zone = zone(forItem: identifier) else { return false }
        if zone.recent != nil { return true }
        return Self.readTypes.contains { !zone.read($0).isEmpty }
    }

    public func forget(_ identifier: Profile.Identifier) {
        zones[identifier] = nil
        observations[identifier] = nil
        preferenceState[identifier] = nil
        documentState[identifier] = nil
        brandState[identifier] = nil
    }

    public var managedZones: [Profile.Identifier] { Array(zones.keys) }

    // MARK: - Hinauf

    /// The channel lists that **belong in this person's zone** — not all of the device's
    /// (on-device test build 1332, 2026-09-27, finding 1).
    ///
    /// **The finding:** ``upload(_:now:onlyNew:)`` wrote every list of the device, including the
    /// password, into **every** profile's zone. A freshly created profile thus carried
    /// someone else's IPTV access in iCloud after the first pass — and a shared profile
    /// (AP44) passed it on to a foreign Apple account. Now only what the person
    /// manages goes up; the same window as for display
    /// (``ProfileKit/channelListWindow(available:)``), including the safety valve for orphaned references.
    nonisolated static func ownLists(
        _ all: [ChannelListAccess], forItem profile: Profile
    ) -> [ChannelListAccess] {
        guard let window = profile.channelListWindow(available: all.map(\.key)) else {
            return all
        }
        return all.filter { window.contains($0.key) }
    }

    /// Writes a person's profile and state into their zone — **only what changed.**
    ///
    /// - Returns: how many records were queued. `0` means: the mirror was
    ///   already right, and that is the common case.
    /// - Parameter nurNeues: writes **only** what the mirror does not have at all yet, and
    ///   deletes nothing. The first-contact case — see ``reconcile(_:now:)``.
    @discardableResult
    public func upload(_ profile: Profile, now: Date = Date(), onlyNew: Bool = false) -> Int {
        guard let zone = zone(forItem: profile.identifier) else { return 0 }
        let state = StillLedger.read(from: store, forItem: profile.identifier.rawValue).state
        var shouldHave =
            ProfileMapping.wordings(forItem: profile, now: now)
            + StillMapping.wordings(forItem: state, now: now)
        if let channelLists {
            shouldHave += ChannelListMapping.wordings(
                forItem: Self.ownLists(channelLists(), forItem: profile), now: now)
        }
        if let preferenceStore {
            // **Only what the person set themselves** — not the device value they
            // fall back to. See ``Core/ProfileStore/own()``.
            let own = ProfileStore(preferenceStore, forItem: profile.identifier.rawValue).own()
            shouldHave += PreferenceMapping.wordings(forItem: own, now: now)
            preferenceState[profile.identifier, default: [:]].merge(own) { _, fresh in fresh }
        }
        // **Home and channel history** (``DocumentPreference``, 2026-09-28) — as a preference, so
        // that no new record type has to be enabled in "Production".
        //
        // **Only what changed here since the last sync** (2026-09-29) — see
        // ``DocumentPreference/wordings(here:top:store:forItem:now:)``.
        let documents = DocumentPreference.values(from: store, forItem: profile.identifier.rawValue)
        shouldHave += DocumentPreference.wordings(
            here: documents, top: { zone.read(contentType: PreferenceMapping.contentType, name: $0) },
            store: store, forItem: profile.identifier.rawValue, now: now)
        documentState[profile.identifier, default: [:]].merge(documents) { _, fresh in fresh }
        if let brandStore {
            let tag = PortalMarkerSlot(brandStore).tag(forItem: profile.identifier)
            shouldHave += PortalMarkerMapping.wordings(forItem: tag, now: now)
            if let tag { brandState[profile.identifier] = tag.digest }
        }
        let written = syncMirror(
            zone, to: shouldHave, now: now, onlyNew: onlyNew,
            cleans: channelLists == nil ? Self.ownTypes : Self.allTypes)
        // **The PIN not via ``syncMirror(_:to:now:onlyNew:cleans:)``** — there
        // the local state would win as soon as it differs from the mirror, even if
        // the mirror carries the younger one. The PIN has its own time, and that decides.
        guard let moveBundle else { return written }
        return written + (passOnPin(profile.identifier, from: moveBundle) ? 1 : 0)
    }

    /// Writes this device's profile PIN into the zone's mirror — **only if it is
    /// younger than what is there** (AP52).
    ///
    /// **Also on first contact**, unlike name and color: the PIN carries the time at which a
    /// human set it (``ProfilePIN/ContentEntryRecord/time``), and the zone merges
    /// by it (``ProfilePINMapping/rule``). A freshly installed device with an old
    /// state thus loses against the cloud instead of beating it with the stamp *now*.
    ///
    /// - Parameter schluesselbund: where the PIN lives on the device — in the app
    ///   ``moveBundle``, in the check a slot of its own.
    /// - Returns: whether a record was queued.
    @discardableResult
    public func passOnPin(_ identifier: Profile.Identifier, from keychain: any KeyValueStore) -> Bool {
        guard let zone = zone(forItem: identifier),
            let here = ProfilePIN(store: keychain, forItem: identifier).entry
        else { return false }
        let top = ProfilePINMapping.entry(from: zone.read(ProfilePINMapping.contentType))
        guard here.resolves(from: top) else { return false }
        zone.write(ProfilePINMapping.message(forItem: here))
        return true
    }

    /// The difference between mirror and target — only it is written.
    ///
    /// **Only what belongs to us is deleted.** A record type this version
    /// does not know stays untouched: it comes from a newer app on the same
    /// account, and whoever clears it takes the other device's state away.
    private func syncMirror(
        _ zone: ProfileZone, to shouldHave: [CloudRecord], now: Date, onlyNew: Bool,
        cleans: [String]
    ) -> Int {
        var written = 0
        var wanted: Set<RecordName> = []

        for message in shouldHave {
            wanted.insert(message.id)
            let available = zone.read(contentType: message.contentType, name: message.name)
            if onlyNew {
                // **The person token is exempt** (cross-check of 2026-09-24). A
                // local token on first contact comes from a share on this
                // device, and a share always brings the person's youngest token. If it were left
                // here, ``download(_:)`` would right afterwards fetch the older one from
                // the cloud over it — and the device would carry a dead token.
                let tag = message.contentType == PortalMarkerMapping.contentType
                guard available == nil || (tag && available?.fields != message.fields) else {
                    continue
                }
            } else {
                // **`changed` and `seal` stay out of the comparison.** The zone sets the one
                // itself, the other belongs to the server; neither says anything about
                // whether the content changed.
                guard available?.fields != message.fields else { continue }
            }
            zone.write(message, now: now)
            written += 1
        }

        // **Nothing is deleted on first contact.** What this device does not know was not
        // thrown away — it just was never here.
        guard !onlyNew else { return written }

        for contentType in cleans {
            for message in zone.read(contentType) where !wanted.contains(message.id) {
                zone.delete(contentType: contentType, name: message.name)
                written += 1
            }
        }
        return written
    }

    /// The record types this app is responsible for.
    ///
    /// `Device` is deliberately **not** included: ``CloudSync/CloudHub`` manages
    /// that record, and a device that is currently switched off must
    /// not drop out of the list just because another one syncs.
    ///
    /// **``ProfileMapping/avatarType`` is not included (AP49, cross-check of
    /// 2026-09-25):** Deselecting goes up as a record with an empty value and not as a
    /// deletion. A book without the field means "never decided" — if this version cleared the
    /// type, the first device after the update with an old mirror would delete the picture everywhere.
    static let ownTypes = [
        ProfileMapping.settingType, ProfileMapping.accessType,
        StillMapping.stillType, StillMapping.channelFavoriteType,
    ]

    /// Plus the channel lists — **only if someone manages them.** See ``channelLists``.
    static let allTypes = ownTypes + [ChannelListMapping.contentType]

    /// What is read and observed: everything cleared **and the preferences, the person
    /// token and the profile picture**, which are never cleared (see
    /// ``PreferenceMapping``, ``PortalMarkerMapping`` and ``ProfileMapping/avatarType``).
    ///
    /// **And the profile PIN (AP52)** — read, never cleared. Its "gone" is a tombstone
    /// (see ``ProfilePINMapping``), and a version that cleared it would take the PIN
    /// away from every other device.
    static let readTypes =
        allTypes + [
            PreferenceMapping.contentType, PortalMarkerMapping.contentType, ProfileMapping.avatarType,
            ProfilePINMapping.contentType,
        ]

    // MARK: - Herunter

    /// Writes profile and state from the zone into this device's books.
    ///
    /// - Returns: whether something changed — the UI should only redraw if
    ///   there is something to draw.
    ///
    /// **A buried profile that is not in the book does not come back here** (B5,
    /// 2026-09-25). ``download(_:)`` puts a profile it reads from the zone into the book —
    /// even one that is currently missing there. That is right for a profile that arrives via a
    /// share link, and wrong for one that was just removed here and whose
    /// zone another device still writes to: the next silent push would put it back into
    /// the switcher. A profile **in** the book, on the other hand, keeps being synced — a note
    /// from remote does not take away the profile someone is just using.
    ///
    /// **A mirror without server contact plays nothing back** (simulator 2026-09-28): It
    /// then carries only what this device itself wrote into it, and the book is
    /// at least as new. Whoever wrote past the book (the person choice on the CL-Server, a
    /// name) otherwise lost their change to the mirror on the next observation pass.
    @discardableResult
    public func download(_ identifier: Profile.Identifier) -> Bool {
        guard let zone = zone(forItem: identifier), zone.recent != nil else { return false }
        guard
            ProfileBook.read(from: store).profile.contains(where: { $0.identifier == identifier })
                || !buriedIDs().contains(Self.norm(identifier))
        else { return false }
        let wordings = Self.readTypes.flatMap { zone.read($0) }
        guard !wordings.isEmpty else { return false }

        var changed = false

        if var fromCloud = ProfileMapping.profile(identifier: identifier, from: wordings) {
            var ledger = ProfileBook.read(from: store)
            let local = ledger.profile.first { $0.identifier == identifier }
            // **If the picture record is missing up there, the local value stays** — missing means "never
            // decided", not "No picture" (that is `""`). See ``ProfileMapping/avatarType``.
            fromCloud.avatar = fromCloud.avatar ?? local?.avatar
            if local != fromCloud {
                ledger.create(fromCloud)
                ledger.write(in: store)
                changed = true
            }
        }

        if let adoptsChannelLists {
            let listen = ChannelListMapping.listen(from: wordings)
            if !listen.isEmpty { adoptsChannelLists(listen) }
        }

        // **Only what is in the cloud is adopted; what is missing stays.** A
        // missing preference means "never set" and not "revoked".
        // And only what changed there since the last sync — see
        // ``preferenceState``.
        if let preferenceStore {
            let state = preferenceState[identifier] ?? [:]
            let fresh = PreferenceMapping.values(from: wordings).filter { state[$0.key] != $0.value }
            let bucket = ProfileStore(preferenceStore, forItem: identifier.rawValue)
            let languageSlot = ProfileStore.bucket(
                AppLanguageSetting.key, forItem: identifier.rawValue)
            let previousLanguage = try? preferenceStore.value(for: languageSlot)
            if bucket.adopt(fresh) { changed = true }
            preferenceState[identifier, default: [:]].merge(fresh) { _, fresh in fresh }
            // **An arrived language applies immediately** (final review 2026-09-25, B-2).
            // Until then it sat in the slot and was only read at the next start: the
            // shell listens to ``Core/AppLanguageSetting/changed``, and only whoever chose
            // themselves posted that (``Core/AppLanguageSetting/write(_:profile:keychain:device:)``).
            // It is posted with the ID as sender; whoever listens reads the active profile's
            // anyway, a foreign one changes nothing there.
            if (try? preferenceStore.value(for: languageSlot)) != previousLanguage {
                NotificationCenter.default.post(
                    name: AppLanguageSetting.changed, object: identifier.rawValue)
            }
        }

        // **Home and channel history** (``DocumentPreference``): only what changed up there since the
        // last sync; the channel history is merged.
        //
        // **By the state, not by the sync** (2026-09-29) — see
        // ``DocumentPreference/fromTop(_:store:forItem:now:)``.
        let remoteDocuments = DocumentPreference.fromTop(
            wordings, store: store, forItem: identifier.rawValue, now: Date())
        if DocumentPreference.adopt(
            Dictionary(remoteDocuments.map { ($0.preference, $0.text) }, uniquingKeysWith: { _, b in b }),
            in: store, forItem: identifier.rawValue)
        {
            changed = true
        }
        let after = DocumentPreference.values(from: store, forItem: identifier.rawValue)
        for entry in remoteDocuments {
            guard let text = after[entry.preference] else { continue }
            DocumentPreference.rememberSynced(
                entry.preference, text, state: entry.state, in: store, forItem: identifier.rawValue)
        }
        documentState[identifier, default: [:]].merge(after) { _, fresh in fresh }

        // **The token like a preference:** what is missing stays (a token has no "gone"), and
        // only what changed up there since the last sync is adopted.
        if let brandStore, let top = PortalMarkerMapping.tag(from: wordings),
            brandState[identifier] != top.digest
        {
            if PortalMarkerSlot(brandStore).create(top, forItem: identifier) { changed = true }
            brandState[identifier] = top.digest
        }

        // **The PIN by its own time** (AP52): what is younger up there is adopted —
        // a tombstone too. What is younger here stays and goes up on the next pass.
        if let moveBundle, let top = ProfilePINMapping.entry(from: wordings),
            ProfilePIN(store: moveBundle, forItem: identifier).adopt(top)
        {
            changed = true
        }

        let fromCloud = StillMapping.state(from: wordings)
        var stillLedger = StillLedger.read(from: store, forItem: identifier.rawValue)
        if stillLedger.state != fromCloud {
            stillLedger.adopt(fromCloud)
            stillLedger.write(in: store, forItem: identifier.rawValue)
            changed = true
        }
        return changed
    }

    // MARK: - The trip to the server

    /// Up, there and back, down — for one profile.
    ///
    /// **On first contact fetch first and then talk**, and what is in the
    /// cloud wins. The reason lies in the books themselves: they keep no
    /// change time per field, so everything this device writes up would carry the
    /// timestamp *now* — and would win against every value of the other device, however old the
    /// local one might be. A phone on which the app was freshly installed would
    /// thus flatten the TV's state.
    ///
    /// **Local data is still not lost:** what the cloud does not know at all yet
    /// is also written up on first contact, and nothing is deleted in the process.
    /// From the second pass the ordinary rule applies — what was changed here is
    /// really newer.
    ///
    /// **If the zone has been deleted in the meantime, the pass ends** (finding 10, 2026-09-27): The
    /// zone's pass reports it via ``CloudSync/ProfileZone/onRemoval``, ``zoneRemoved(_:_:)``
    /// clears the profile — and a ``upload(_:now:onlyNew:)`` afterwards would put it
    /// into a new zone with the state from just now. A lock already on disk (the
    /// app ended between lock and notification) is made good here.
    @discardableResult
    public func reconcile(_ profile: Profile, now: Date = Date()) async -> Bool {
        guard let zone = zone(forItem: profile.identifier) else { return false }
        if let reason = zone.removed {
            zoneRemoved(profile.identifier, reason)
            return true
        }
        inProgress.insert(profile.identifier)
        defer { inProgress.remove(profile.identifier) }

        let firstContact = zone.recent == nil
        if firstContact { await zone.reconcile() }
        guard zones[profile.identifier] === zone else { return true }
        upload(profile, now: now, onlyNew: firstContact)
        // **This device registers itself** (2026-10-01, device list under "Devices & Sharing").
        // In StoryShelf ``CloudSync/CloudHub`` does that when binding a zone; here
        // the zones arise in ``zone(forItem:)`` and never passed this spot —
        // the device list stayed empty. At most once per hour, which
        // ``CloudSync/CloudHub/writeDevice(in:)`` handles itself; an assigned name stays.
        hub.writeDevice(in: zone)
        await zone.reconcile()
        guard zones[profile.identifier] === zone else { return true }
        return download(profile.identifier)
    }

    /// The same for all profiles of the book.
    ///
    /// **First catch up with the move notes** (cross-check strand C, R2): Otherwise
    /// a profile that another device put into a second one would go up here once more —
    /// together with everything seen under it since, into a zone that
    /// nobody reads anymore.
    @discardableResult
    public func syncAll(now: Date = Date()) async -> Bool {
        var changed = !followTombstones(now: now).isEmpty
        for profile in ProfileBook.read(from: store).profile {
            if await reconcile(profile, now: now) { changed = true }
        }
        return changed
    }

    /// A pass if the cadence allows it — the ordinary path for the UI.
    ///
    /// - Returns: whether something changed in the books. `false` also means "the
    ///   brake was on" — and for the caller that is the same: nothing to redraw.
    @discardableResult
    public func syncIfNeeded(
        _ reason: SyncCadence.Occasion, now: Date = Date()
    ) async
        -> Bool
    {
        guard cadence.isAllowed(reason, now: now) else { return false }
        return await syncAll(now: now)
    }

    /// A silent push from CloudKit.
    ///
    /// - Returns: whether the push belonged to this app. `false` means: not ours — the
    ///   caller should pass it on and not swallow it.
    @discardableResult
    public func process(push: [AnyHashable: Any]) async -> Bool {
        guard await hub.process(push: push) else { return false }
        // The zones have already done their pass; what arrived the observation has already
        // written into the book. The cadence is still noted so that
        // another pass does not follow right after.
        _ = cadence.isAllowed(.push)
        return true
    }

    // MARK: - Finden

    /// The profiles that are in the cloud and not yet on this device.
    ///
    /// **This is the sentence AP43 is built for:** "Same Apple ID = same
    /// profile, without a scan." A profile created on the iPhone then appears in the switcher on the Apple TV
    /// without anyone creating it there again.
    ///
    /// **A profile without a name is skipped.** A zone that is only just coming into being
    /// does not have its `name` record yet; building an empty profile from it would mean
    /// putting an empty circle into the switcher that nobody can address.
    ///
    /// **A buried profile is not found** (AP43 · B5, 2026-09-25) — see
    /// ``ProfileTombstone``. The notes come from three sources, and each catches a case
    /// the others do not see: from the device (just removed, still without a network), from the
    /// household zone's mirror (written, not yet up) and **from the server itself**
    /// (another device removed it). The last source is read fresh here
    /// and not from the mirror: on a device's first start the household zone has
    /// not done a pass yet, and exactly then ``find()`` runs.
    ///
    /// **If the server cannot be read reliably, nothing is found.** `nil` would mean two
    /// things here — "no notes" and "not asked" —, and the second reading would bring back a
    /// removed profile just because the network stalled at that moment. A
    /// household zone that does not exist (`zoneMissing`), on the other hand, is a real answer: then
    /// nobody ever noted anything.
    ///
    /// **And what is noted only on the device goes up on that occasion** — a
    /// profile that was removed without an Apple account should not come back via another
    /// device as soon as one is there.
    ///
    /// **And this is where the notes expire** (finding 8): What is older than
    /// ``ProfileTombstone/retention`` goes along with the dead zone — without the zone the
    /// next call would otherwise find it as a new profile. If deleting the zone fails, the
    /// note stays.
    ///
    /// **Expired means, since 2026-09-25: proven on the server** (final review,
    /// C2-3). The zone is only deleted if the note demonstrably has been up there for 180 days
    /// (``ProfileTombstone/isOldEnough(_:serverClock:)``) — expiring by the device's
    /// clock is not enough, whoever sits in front of it sets that. As long as the proof is missing,
    /// **the note stays and keeps applying**: if it were cleared without the zone, the
    /// next call would find the zone as a new profile, and the removal would be undone.
    public func find(now: Date = Date()) async -> [Profile] {
        await scan(now: now, hidden: false) ?? []
    }

    /// What a search in iCloud answered — **"found nothing" kept apart from "could not
    /// read"** (AP88).
    ///
    /// ``find(now:)`` folds both into `[]`, and for the sync that is right: a stalled read
    /// must not look like a removal. The first setup on a fresh TV asks a different
    /// question — "does this household already have profiles?" — and there the two answers
    /// lead to different screens: an empty iCloud offers "New profile", an unread one waits
    /// for its deadline.
    public enum Reading: Sendable, Equatable {
        /// Read; the profiles not yet on this device, possibly none.
        case found([Profile])
        case noAccount
        /// Restricted by Screen Time or a device-management profile.
        case restricted
        /// Account status unknown, or a read failed.
        case unread
    }

    /// ``find(now:)`` with the reason when nothing could be read — see ``Reading``.
    public func findReporting(now: Date = Date()) async -> Reading {
        guard let service = hub.service else { return .unread }
        switch await service.accountStatus() {
        case .available: break
        case .noAccount: return .noAccount
        case .restricted: return .restricted
        case .unknown: return .unread
        }
        guard let found = await scan(now: now, hidden: false) else { return .unread }
        return .found(found)
    }

    /// The profiles that are **hidden on this device** and live on in iCloud —
    /// the selection for "add existing profiles" (``ProfileHiding``).
    ///
    /// The same search as ``find(now:)``, including tombstones: a profile that another
    /// device has meanwhile deleted everywhere is no longer offered here.
    public func findHidden(now: Date = Date()) async -> [Profile] {
        await scan(now: now, hidden: true) ?? []
    }

    /// **Explicitly** brings hidden profiles back into this device's book — the
    /// note falls, then it goes the same way as a found profile
    /// (``adopt(_:now:)``).
    @discardableResult
    public func restore(_ profileEntry: [Profile], now: Date = Date()) -> Int {
        for profileName in profileEntry { ProfileHiding.lift(profileName.identifier, in: store) }
        let changed = adopt(profileEntry, now: now)
        Diagnostics.step(
            "Profile: \(profileEntry.count) hidden item(s) restored", since: nil, area: "Wolke")
        return changed
    }

    /// "Remove from this device": the zone is no longer managed here and is skipped at the next
    /// ``find(now:)`` — **in iCloud and on the other devices it stays.**
    public func hide(_ identifier: Profile.Identifier) {
        ProfileHiding.create(identifier, in: store)
        forget(identifier)
        cleanUpMirror(identifier)
    }

    /// "Delete everywhere": delete the profile's zone **now** and not only when the
    /// tombstone expires after ``ProfileTombstone/retention`` (owner request 2026-09-27).
    ///
    /// **The tombstone comes first** (``bury(_:target:now:)``) and stays: A deleted
    /// zone comes back up as soon as a device that still has the profile in its book does
    /// a pass (see ``ProfileTombstone``). The note makes sure every device removes it from its
    /// book (``followTombstones(additionally:now:)``) — only with that is deleted really
    /// deleted. A merge (AP45) never calls this: its tombstone stays revocable.
    ///
    /// **Only a zone of one's own.** A shared one belongs to another Apple account; whoever only
    /// reads along leaves the share (``leave(_:)``).
    ///
    /// - Returns: whether the zone is gone (also: it never existed or there is no cloud).
    @discardableResult
    public func deleteZone(_ identifier: Profile.Identifier) async -> Bool {
        forget(identifier)
        cleanUpMirror(identifier)
        guard let zone = ProfileMapping.zone(forItem: identifier) else { return false }
        do throws(CloudError) {
            try await hub.delete(zone)
        } catch .zoneMissing {
            // bewusst still: already gone — the goal is reached.
        } catch {
            Diagnostics.defect(
                "Profile zone not deleted: \(Diagnostics.explain(error))", since: nil,
                area: "Wolke")
            return false
        }
        Diagnostics.step("Profile zone permanently deleted", since: nil, area: "Wolke")
        return true
    }

    /// Throws a zone's mirror off the disk — **otherwise it would come back up** as soon as someone
    /// asks ``zone(forItem:)``: the zone would read its mirror and write it up.
    private func cleanUpMirror(_ identifier: Profile.Identifier) {
        guard let file = mirrorFolder?.appending(path: "wolke-\(identifier.rawValue).json") else {
            return
        }
        try? FileManager.default.removeItem(at: file)
    }

    /// - Returns: `nil` if the zones or the tombstones could not be read.
    private func scan(now: Date, hidden: Bool) async -> [Profile]? {
        guard let service = hub.service else { return nil }
        guard var marker = try? await service.zones(shared: false) else { return nil }
        guard let read = await remoteTombstones(service) else { return nil }
        var top = read.entries
        let expire = await cleanUpExpired(
            top, serverClock: read.serverClock, service: service, now: now)
        let pending = ProfileTombstone.newest(top).filter {
            $0.expired(now: now) && !expire.contains(Self.norm($0.identifier))
        }
        let unproven = Set(pending.filter { !$0.lifted }.map { Self.norm($0.identifier) })
        if !pending.isEmpty {
            household()?.write(ProfileTombstone.clockRecord(now: now), now: now)
        }
        top.removeAll { entry in expire.contains(Self.norm(entry.identifier)) }
        marker.removeAll { zone in
            Self.identifier(from: zone).map { expire.contains(Self.norm($0)) } ?? false
        }
        uploadTombstones(top: top)
        // **Catch up with the move notes from remote before searching** — a profile that
        // another device merged should not be found here once more first.
        followTombstones(additionally: top, now: now)
        let known = Set(ProfileBook.read(from: store).profile.map(\.identifier))
        let buried = buriedIDs(additionally: top, now: now).union(unproven)
        // **What is hidden here does not come back by itself** — only on request
        // (``findHidden(now:)``). See ``ProfileHiding``.
        let hiddenHere = ProfileHiding.all(from: store)

        var found: [Profile] = []
        foundRecords = [:]
        for zone in marker where zone.isProfile {
            guard let identifier = Self.identifier(from: zone), !known.contains(identifier),
                !buried.contains(Self.norm(identifier)),
                hiddenHere.contains(Self.norm(identifier)) == hidden
            else {
                continue
            }
            let wordings =
                (try? await service.changes(zone, since: nil).changed) ?? []
            guard let profile = ProfileMapping.profile(identifier: identifier, from: wordings) else {
                continue
            }
            found.append(profile)
            foundRecords[identifier] = wordings
        }
        return found
    }

    /// What ``find()`` last read per found profile — for ``adopt(_:now:)``,
    /// when this device's ID wins and the cloud ID's state is absorbed into it.
    private var foundRecords: [Profile.Identifier: [CloudRecord]] = [:]

    /// Takes the found profiles into the book — **without switching an active one.**
    ///
    /// Whoever is watching should not land on another profile in the middle of a film
    /// just because one was created on the iPhone.
    ///
    /// **Until 2026-09-24 this compared only IDs, and that produced two identical profiles**
    /// (AP48). **Each device** assigns an ID **fresh on first start**
    /// (``ProfileKit/Identifier/fresh()``, called in ``ProfileBook/adopt(jellyfin:…)``),
    /// so the same person has a different one on the TV than on the phone. When
    /// iCloud was switched on, it stood twice in the switcher — and whoever took the wrong one did not find
    /// their state. ``ProfileSync`` now merges by name.
    ///
    /// **The return value no longer counts only new ones**, but every change to the book: A
    /// merge adds nothing and still changes something.
    ///
    /// **Since C2 the order is note, book, move, tombstone** (cross-check
    /// strand C, R1–R3). The note on the device (``ProfileTombstone``) comes first and makes
    /// the operation repeatable: if the app crashes after the book, the next run
    /// catches up (``followTombstones(additionally:now:)``, at the end of this call). The
    /// tombstone in the household zone comes last and makes sure the abandoned
    /// zone is not found again at the next start — until C2 it was missing, and the
    /// ID **oscillated** on every start, with state, PIN and parental controls.
    ///
    /// **Which ID stays is decided by ``ProfileSync/wins(_:about:)``.** If this
    /// device's wins, the cloud ID is absorbed into it: its state from the cloud is added with
    /// the rule "earlier place wins", and its tombstone shows the device it
    /// belongs to where to follow.
    @discardableResult
    public func adopt(_ profile: [Profile], now: Date = Date()) -> Int {
        // **The operation itself lives in ``ProfileSync/adopt(cloud:in:)``** and not
        // here: This holder needs CloudKit, and with that the whole chain could not be checked without
        // a cloud. Exactly that hid a bug on 2026-09-24.
        let result = ProfileSync.merge(
            device: ProfileBook.read(from: store).profile, cloud: profile)

        for (old, fresh) in result.moves {
            ProfileTombstone.create(old, target: fresh, now: now, in: store)
        }
        // **The PIN of the found profiles first** (AP52) — before the move asks whether
        // the remaining one has one. Without this line a profile protected on the phone would stand here
        // open in the switcher until the first pass: ``download(_:)`` only runs there.
        if let moveBundle {
            for (identifier, wordings) in foundRecords {
                guard let top = ProfilePINMapping.entry(from: wordings) else { continue }
                ProfilePIN(store: moveBundle, forItem: identifier).adopt(top)
            }
        }
        let changed = ProfileSync.adopt(cloud: profile, in: store)
        // **Everything attached to the ID moves along** (AP45, AP47): state, shelves,
        // preferences, parental controls, PIN, start choice, person token — see ``ProfileMove``.
        for (old, fresh) in result.migrated {
            ProfileMove.migrate(
                from: old, after: fresh, ledgerStore: store, keychain: moveBundle,
                startStore: startStore)
        }
        for (cloudID, remains) in result.absorbed {
            takeState(from: cloudID, in: remains)
            if let moveBundle {
                ProfileMove.movePIN(from: cloudID, after: remains, in: moveBundle)
            }
        }
        for (old, fresh) in result.moves {
            bury(old, target: fresh, now: now)
        }
        followTombstones(now: now)
        // **One line for the whole sync** (diagnostics coverage, 2026-09-27): number of
        // entries from the cloud, what changed, and — this was nowhere to be
        // seen so far — how many pairs remained unresolved. No name, no ID: A
        // user who finds two copies of the same profile in the switcher should see that confirmed here,
        // without the line itself naming a person.
        if !result.toAsk.isEmpty {
            Diagnostics.defect(
                "Profile reconciliation: \(profile.count) from the cloud, \(changed) changed, \(result.toAsk.count) unresolved (same access, different name)",
                since: nil, area: "Wolke")
        } else if changed > 0 {
            Diagnostics.step(
                "Profile reconciliation: \(profile.count) from the cloud, \(changed) changed, \(result.moves.count) moved",
                since: nil, area: "Wolke")
        }
        return changed
    }

    /// The state of an absorbed cloud ID, as ``find()`` read it — into the
    /// Standbuch of the ID that stays. **Earlier place wins**, as with the move.
    private func takeState(from cloudID: Profile.Identifier, in remains: Profile.Identifier) {
        guard let wordings = foundRecords[cloudID] else { return }
        // **The channel history comes along** (2026-09-28) — merged, as with the move.
        if let history = wordings.first(where: {
            $0.contentType == PreferenceMapping.contentType && $0.name == DocumentPreference.channelHistory
        })?[PreferenceMapping.valueField]?.text {
            DocumentPreference.adopt(
                [DocumentPreference.channelHistory: history], in: store, forItem: remains.rawValue)
        }
        let top = StillMapping.state(from: wordings)
        guard top != StateRecording() else { return }
        let here = StillLedger.read(from: store, forItem: remains.rawValue)
        StillLedger(state: ProfileMove.merge(here.state, using: top), journal: here.journal)
            .write(in: store, forItem: remains.rawValue)
    }

    /// Where ``StartChoice`` lives — for the move of a migrated ID. `nil` leaves it
    /// alone (checks that should not touch the standard store).
    public var startStore: UserDefaults? = .standard

    // MARK: - Grabsteine (B5)

    /// Notes that a profile has disappeared on purpose — **on the device and in the
    /// household zone**, and the zone is no longer managed.
    ///
    /// Called on removal and on merging (``ProfileKit/ProfileMerge``). The
    /// zone stays in iCloud; why that is the safe choice is explained at
    /// ``ProfileTombstone``.
    public func bury(
        _ identifier: Profile.Identifier, target: Profile.Identifier? = nil, now: Date = Date()
    ) {
        ProfileTombstone.create(identifier, target: target, now: now, in: store)
        household()?.write(
            ProfileTombstone.message(
                forItem: .init(identifier: identifier, target: target, datum: now), now: now),
            now: now)
        forget(identifier)
    }

    /// Revokes the note — when the same profile explicitly comes back.
    ///
    /// **As a record "lifted" and not as a deletion** (finding 8): A deletion would look, on
    /// a device that still keeps the note locally, like "it is missing up there" — and
    /// ``find(now:)`` would write it up there again. The lifted record is younger
    /// than any old note and therefore applies everywhere.
    public func liftTombstone(_ identifier: Profile.Identifier, now: Date = Date()) {
        ProfileTombstone.lift(identifier, in: store)
        household()?.write(
            ProfileTombstone.message(
                forItem: .init(identifier: identifier, datum: now, lifted: true), now: now),
            now: now)
    }

    /// All notes known here: from the device, from the household zone's mirror
    /// and, if supplied, from the server.
    func tombstones(
        additionally: [ProfileTombstone.ContentEntryRecord] = []
    ) -> [ProfileTombstone.ContentEntryRecord] {
        ProfileTombstone.all(from: store)
            + ProfileTombstone.entries(from: household()?.read(ProfileTombstone.contentType) ?? [])
            + additionally
    }

    /// The applicable notes as normalized IDs.
    func buriedIDs(
        additionally: [ProfileTombstone.ContentEntryRecord] = [], now: Date = Date()
    ) -> Set<String> {
        Set(
            ProfileTombstone.applicable(tombstones(additionally: additionally), now: now)
                .map { Self.norm($0.identifier) })
    }

    /// Catches up with the move notes — see
    /// ``ProfileMove/episode(_:ledgerStore:keychain:startStore:now:)``.
    ///
    /// **Called at startup (``find(now:)``, ``adopt(_:now:)``), on every pass
    /// (``syncAll(now:)``) and when a note arrives from remote** (observation of the
    /// household zone). The zone of a source that was caught up with is no longer managed here.
    @discardableResult
    func followTombstones(
        additionally: [ProfileTombstone.ContentEntryRecord] = [], now: Date = Date()
    ) -> [Profile.Identifier] {
        let notes = tombstones(additionally: additionally)
        let migrated = ProfileMove.episode(
            notes, ledgerStore: store, keychain: moveBundle,
            startStore: startStore, now: now)
        for source in migrated { forget(source) }
        return migrated + followDeletions(notes, now: now)
    }

    /// Takes what another device **deleted everywhere** out of this book too — an
    /// applicable tombstone **without a target** (owner request 2026-09-27).
    ///
    /// **The finding:** Until here only ``find(now:)`` skipped a buried profile. A
    /// device that already had it in its book kept it — and its next pass created the zone
    /// again (``ProfileTombstone``: "a deleted zone comes back up"). "Delete
    /// everywhere" thus meant "delete on this device, and in iCloud it comes back".
    ///
    /// **What is attached to the ID goes along** — state, shelves, PIN; if the person was sitting in front,
    /// nobody sits in front afterwards, and the next start asks "Who's watching?".
    ///
    /// - Returns: the IDs that disappeared here.
    private func followDeletions(
        _ notes: [ProfileTombstone.ContentEntryRecord], now: Date
    ) -> [Profile.Identifier] {
        let deleted = Set(
            ProfileTombstone.applicable(notes, now: now).filter { $0.target == nil }
                .map { Self.norm($0.identifier) })
        guard !deleted.isEmpty else { return [] }
        var ledger = ProfileBook.read(from: store)
        let leaving = ledger.profile.filter { deleted.contains(Self.norm($0.identifier)) }.map(\.identifier)
        guard !leaving.isEmpty else { return [] }
        let wasActive = ledger.active.map(leaving.contains) ?? false
        for identifier in leaving { ledger.remove(identifier) }
        if wasActive { ledger.clearActive() }
        ledger.write(in: store)
        for identifier in leaving {
            StillLedger().write(in: store, forItem: identifier.rawValue)
            ShelfOrder().write(in: store, forItem: identifier.rawValue)
            if let moveBundle { ProfilePIN(store: moveBundle, forItem: identifier).forget() }
            forget(identifier)
            cleanUpMirror(identifier)
            if ProfilePointer.active == identifier.rawValue { ProfilePointer.show(to: nil) }
        }
        Diagnostics.step(
            "Tombstones: \(leaving.count) profile(s) deleted remotely", since: nil, area: "Wolke")
        return leaving
    }

    /// The notes **on the server** — `nil` if that cannot be said reliably.
    ///
    /// **With the household zone's youngest server date** (C2-3): It is the server's "now"
    /// that ``cleanUpExpired(_:serverClock:service:now:)`` calculates against.
    private func remoteTombstones(
        _ service: any CloudService
    ) async -> (entries: [ProfileTombstone.ContentEntryRecord], serverClock: Date?)? {
        do throws(CloudError) {
            let wordings = try await service.changes(PINFallback.zone, since: nil).changed
            return (ProfileTombstone.entries(from: wordings), ProfileTombstone.serverClock(from: wordings))
        } catch .zoneMissing, .deletedByUser {
            // bewusst still: Without a zone there was never a tombstone — or the human deleted it in
            // the iOS settings, and with it every profile. The empty list is
            // the answer.
            return ([], nil)
        } catch {
            Diagnostics.defect(
                "Tombstones above not read: \(Diagnostics.explain(error))", since: nil, area: "Wolke")
            return nil
        }
    }

    /// What is noted only on the device — or younger there than up there — into the household zone.
    ///
    /// **And what was lifted younger up there drops out on the device**: Then another
    /// device explicitly brought the profile back after it was buried here.
    private func uploadTombstones(top: [ProfileTombstone.ContentEntryRecord]) {
        guard let zone = household() else { return }
        let there = ProfileTombstone.newest(
            top + ProfileTombstone.entries(from: zone.read(ProfileTombstone.contentType)))
        let perIdentifier = Dictionary(
            there.map { (Self.norm($0.identifier), $0) }, uniquingKeysWith: { first, _ in first })
        for entry in ProfileTombstone.all(from: store) {
            guard let top = perIdentifier[Self.norm(entry.identifier)] else {
                zone.write(ProfileTombstone.message(forItem: entry))
                continue
            }
            if (entry.datum ?? .distantPast) > (top.datum ?? .distantPast) {
                zone.write(ProfileTombstone.message(forItem: entry))
            } else if top.lifted {
                ProfileTombstone.lift(entry.identifier, in: store)
            }
        }
    }

    /// Clears expired notes — on the device and up there, and for a tombstone the dead
    /// zone along with it.
    ///
    /// **Up there only what is proven on the server** (C2-3): expired by the device's
    /// clock **and** by the server's (``ProfileTombstone/isOldEnough(_:serverClock:)``).
    /// On the device ``ProfileTombstone/cleanUp(now:in:)`` clears as before — no
    /// zone lives there, and as long as the note stands up there it keeps applying via `top`.
    ///
    /// - Returns: the normalized IDs of the notes that expired and were cleared up there.
    private func cleanUpExpired(
        _ top: [ProfileTombstone.ContentEntryRecord], serverClock: Date?, service: any CloudService, now: Date
    ) async -> Set<String> {
        ProfileTombstone.cleanUp(now: now, in: store)
        var cleaned: Set<String> = []
        for entry in ProfileTombstone.newest(top)
        where entry.expired(now: now)
            && ProfileTombstone.isOldEnough(entry, serverClock: serverClock)
        {
            if !entry.lifted, let zone = ProfileMapping.zone(forItem: entry.identifier) {
                do throws(CloudError) {
                    try await service.delete(zone)
                } catch .zoneMissing {
                    // bewusst still: already gone — then only the note is left to clear.
                } catch {
                    Diagnostics.defect(
                        "Profile zone not deleted: \(Diagnostics.explain(error))", since: nil,
                        area: "Wolke")
                    continue
                }
            }
            household()?.delete(contentType: ProfileTombstone.contentType, name: entry.identifier.rawValue)
            cleaned.insert(Self.norm(entry.identifier))
        }
        // **Final means final** — the one place where a profile zone really
        // disappears should appear in the report, without the line naming an ID.
        if !cleaned.isEmpty {
            Diagnostics.step(
                "Tombstones: \(cleaned.count) profile zone(s) permanently cleared", since: nil,
                area: "Wolke")
        }
        return cleaned
    }

    /// Siehe ``ProfileTombstone/norm(_:)``.
    static func norm(_ identifier: Profile.Identifier) -> String { ProfileTombstone.norm(identifier) }

    // MARK: - Koppeln (AP44)

    /// **Direction 1:** This device has the profile and hands it out. The return value is
    /// the sharing link that a QR code carries.
    public func split(
        _ identifier: Profile.Identifier, title: String
    ) async throws(CloudError)
        -> URL
    {
        guard let zone = ProfileMapping.zone(forItem: identifier) else {
            throw CloudError.other("Profile ID without a zone")
        }
        // **Sync before sharing.** Otherwise the other person gets a zone holding
        // yesterday's state — and only notices when they miss something.
        if let profile = ProfileBook.read(from: store).profile.first(where: { $0.identifier == identifier }) {
            _ = await reconcile(profile)
        }
        let approval = try await hub.split(zone, title: title)
        guard let url = approval.url else {
            throw CloudError.other("Share without a link")
        }
        return url
    }

    /// **Direction 2, giving side:** The phone puts the sharing link under the code
    /// into the public mailbox.
    ///
    /// - Parameter geraet: the name of **this** device, for the reply over there.
    public func store(
        _ identifier: Profile.Identifier, code: String, title: String, device: String
    ) async throws(CloudError) {
        guard let service = hub.service else { throw CloudError.noAccount }
        let link = try await split(identifier, title: title)
        try await service.putPublic(Pairing.store(code: code, link: link, device: device))
    }

    /// **Direction 2, picking-up side:** The TV checks whether something lies
    /// under its code.
    ///
    /// **Picked up means gone.** The entry is deleted as soon as it has been read — and
    /// **before** the share is accepted: If acceptance fails, the link is used up
    /// anyway. That is the safe direction; the other way round a valid key would
    /// stay in the public mailbox because a later step failed.
    ///
    /// - Returns: `nil` as long as nobody has answered — that is the normal case when
    ///   polling and not an error.
    public func fetchPairing(
        code: String, now: Date = Date()
    ) async throws(CloudError)
        -> Pairing.Transmission?
    {
        guard let service = hub.service else { throw CloudError.noAccount }
        let name = Pairing.name(forItem: code)
        guard let message = try await service.readPublic(name) else { return nil }
        try await service.deletePublic(name)
        return Pairing.broadcast(from: message, now: now)
    }

    /// Accepts a share and puts the profile into the book.
    ///
    /// **The profile comes from the zone and not from the link.** Name and color are in it
    /// as ``ProfileMapping/settingType``; the link only says which zone it
    /// is. Whoever took the name from the share title would have it
    /// wrong at the first rename.
    ///
    /// **The profile is created even if the zone yields nothing yet** — as in
    /// StoryShelf (`Appkern.nimmFreigabeAn`, `legeGeteilt`). On-device test 2026-09-28: "has
    /// arrived", but it was not among the profiles. Until then the profile only reached the book
    /// via ``download(_:)``, and that stays silent as long as the mirror has no
    /// state yet or the zone is empty — for instance because the TV could never upload it until finding
    /// F-025. Name and color then come from the share, the rest at the next sync.
    ///
    /// - Parameter ersatzname: the name from the QR code, in case the share carries none.
    @discardableResult
    public func accept(_ link: URL, fallbackName: String? = nil) async throws(CloudError) -> Profile? {
        let accepted = try await hub.accept(url: link)
        guard let identifier = Self.identifier(from: accepted.zone) else {
            Diagnostics.defect("Share accepted, but no profile zone", since: nil, area: "Wolke")
            return nil
        }
        // **Whoever accepts a link wants exactly this profile** — even if it was once
        // removed here. Otherwise ``download(_:)`` would hold it back at the note.
        liftTombstone(identifier)

        // **The own zone (same Apple ID) takes the path of ``find()``** — like
        // "Adopt" in StoryShelf: read records, merge via ``adopt(_:now:)``
        // (same name, move, PIN), then sync the mirror and everything into the book. Without
        // that, a second profile of the same name would sit next to the existing one.
        if !accepted.zone.shared, let service = hub.service {
            let wordings = (try? await service.changes(accepted.zone, since: nil).changed) ?? []
            if let found = ProfileMapping.profile(identifier: identifier, from: wordings) {
                foundRecords[identifier] = wordings
                adopt([found])
                if ProfileBook.read(from: store).profile.contains(where: { $0.identifier == identifier }) {
                    await zone(forItem: identifier)?.reconcile()
                    _ = download(identifier)
                }
                notify()
                let ledger = ProfileBook.read(from: store).profile
                Diagnostics.step(
                    "Profile taken over from the own zone (\(wordings.count) sentences)", since: nil,
                    area: "Wolke")
                return ledger.first { $0.identifier == identifier } ?? ledger.first { $0.name == found.name }
            }
        }

        let zone = zone(forItem: identifier)
        zone?.bind(on: accepted.zone)
        // With the same Apple ID it is the own zone (``CloudSync/ZoneID/ownAccount``)
        // — then the profile is not "shared by" someone.
        zone?.sharedBy = accepted.zone.shared ? accepted.ownerName : nil
        await zone?.reconcile()
        _ = download(identifier)

        var ledger = ProfileBook.read(from: store)
        // **Posted in every case** — otherwise the profile list on the phone only re-reads at the
        // next start, and the profile would look like it had disappeared.
        defer { notify() }
        if let da = ledger.profile.first(where: { $0.identifier == identifier }) { return da }
        let name = accepted.profileName ?? fallbackName ?? accepted.ownerName ?? "iCloud"
        let color = accepted.color.flatMap(Profile.ColorTag.init(rawValue:)) ?? .amber
        let profile = Profile(identifier: identifier, name: name, color: color)
        ledger.create(profile)
        ledger.write(in: store)
        Diagnostics.step(
            "Profile created from the share — the zone had no state yet (mirror "
                + "\(zone?.recent == nil ? "never" : "already") reconciled)",
            since: nil, area: "Wolke")
        return profile
    }

    // MARK: - The household (AP43)

    /// The **device's** zone and not a human's — see ``PINFallback``.
    ///
    /// **It is never shared**, and the whole recovery path rests on that: If it lay in
    /// a profile zone, a foreign Apple account could, since AP44, lift this household's
    /// parental controls.
    ///
    /// **It is created by itself.** ``CloudSync/ProfileZone`` catches `.zoneMissing` for an
    /// own zone and creates it; hence there is no `create` here.
    public func household() -> ProfileZone? {
        if let available = householdZone { return available }
        guard hub.service != nil else { return nil }
        let zone = ProfileZone(
            file: mirrorFolder?.appending(path: "wolke-haushalt.json"),
            service: hub.service, zone: PINFallback.zone, automatic: automatic)
        householdZone = zone
        hub.register(zone)
        zone.onRemoval = { [weak self] reason in self?.householdRemoved(reason) }
        if let reason = zone.removed { householdRemoved(reason) }
        householdWatch = zone.observe(PINFallback.contentType) { [weak self] _ in
            self?.pinEscape?()
        }
        // **A move note from remote is followed immediately** (cross-check strand C, R2) —
        // not only at the next pass. Whoever is sitting in the merged profile would
        // otherwise write into the dead zone until then.
        tombstoneWatch = zone.observe(ProfileTombstone.contentType) { [weak self] _ in
            guard let self, !self.followTombstones().isEmpty else { return }
            self.notify()
        }
        return zone
    }

    private var tombstoneWatch: ObservationResult?

    /// Called when something happened at the recovery path — from remote or here.
    ///
    /// **A callback and not an observable field**, for the same reason as with
    /// ``arrival``: The truth is in the zone, not in this object.
    public var pinEscape: (@MainActor () -> Void)?

    /// The state of the recovery path for **this** profile, as this device sees it.
    public func pinState(
        forItem lock: PINFallback.Lock, now: Date = Date()
    )
        -> PINFallback.State
    {
        PINFallback.state(
            from: household()?.read(
                contentType: PINFallback.contentType, name: PINFallback.name(forItem: lock)),
            now: now)
    }

    /// The open requests for the **profile** PINs — for the hints on the TV
    /// (cross-check strand C, finding 6).
    ///
    /// **The recovery path per profile ran out invisibly until C2.** The request lay in the
    /// household zone, the deadline ran, and after 24 hours the PIN dropped — without the TV
    /// saying anywhere that someone had asked for it. With the parental-controls recovery path the
    /// deadline is on the PIN sheet (``PINFallback``); here there is one per
    /// profile, and this list is the source for all places that show it.
    public func openProfileRecoveries(now: Date = Date()) -> [Profile.Identifier: PINFallback.State] {
        guard let zone = household() else { return [:] }
        var pending: [Profile.Identifier: PINFallback.State] = [:]
        for message in zone.read(PINFallback.contentType) {
            guard let identifier = PINFallback.profile(fromName: message.name) else { continue }
            let state = PINFallback.state(from: message, now: now)
            if state.pending { pending[identifier] = state }
        }
        return pending
    }

    /// "PIN forgotten" — file the request.
    ///
    /// **A second request extends nothing.** Whoever already has an open one gets it
    /// back; otherwise every press of the button would reset the clock, and the deadline could be
    /// renewed any number of times — by the same human who wants to get rid of it.
    @discardableResult
    public func requestPinRecovery(
        forItem lock: PINFallback.Lock, device: String, now: Date = Date()
    ) -> PINFallback.State {
        guard let zone = household() else { return .none }
        let name = PINFallback.name(forItem: lock)
        let available = zone.read(contentType: PINFallback.contentType, name: name)
        if available != nil { return PINFallback.state(from: available, now: now) }
        zone.write(
            PINFallback.request(forItem: lock, device: device, now: now), now: now)
        return PINFallback.state(from: zone.read(contentType: PINFallback.contentType, name: name), now: now)
    }

    /// Confirm — **from the second device.**
    ///
    /// - Returns: `false` if no request is open at all. That is the normal case with
    ///   a push that reports an already cancelled request.
    @discardableResult
    public func confirmPinRecovery(
        forItem lock: PINFallback.Lock, device: String, now: Date = Date()
    ) -> Bool {
        guard let zone = household(),
            let message = zone.read(
                contentType: PINFallback.contentType, name: PINFallback.name(forItem: lock))
        else { return false }
        zone.write(PINFallback.confirmation(zu: message, finished: device), now: now)
        return true
    }

    /// Cancel — **from any device, and without a PIN.**
    ///
    /// Whoever knows the PIN should not have to carry the cancellation through it first:
    /// Cancelling is the *cautious* direction, and a hurdle in front of it would mean that an
    /// accidentally filed request stays standing.
    public func cancelPinRecovery(forItem lock: PINFallback.Lock) {
        household()?.delete(contentType: PINFallback.contentType, name: PINFallback.name(forItem: lock))
    }

    /// The request is settled — the lock has fallen or been set anew.
    public func closePinRecovery(forItem lock: PINFallback.Lock) {
        cancelPinRecovery(forItem: lock)
    }

    // MARK: - The participant side (AP44)

    /// Who reads along on this profile — **and `nil` as long as it is not shared.**
    ///
    /// **Without this list, sharing would be a process without a way back.** A link that
    /// someone has once accepted stays valid; whoever wants to revoke it must first be
    /// able to see who has it.
    public func approval(_ identifier: Profile.Identifier) async throws(CloudError) -> AccessGrant? {
        guard let zone = ProfileMapping.zone(forItem: identifier) else { return nil }
        return try await hub.approval(zone)
    }

    /// Lock a participant out — the owner, from their own device.
    public func remove(
        participant: String, from identifier: Profile.Identifier
    ) async throws(CloudError) {
        guard let zone = ProfileMapping.zone(forItem: identifier) else {
            throw CloudError.other("Profile ID without a zone")
        }
        try await hub.remove(participant: participant, from: zone)
    }

    /// End the share entirely — all participants at once.
    ///
    /// **That invalidates the link**, and that is the point: A sharing link has no
    /// expiry date. As long as the share stands, everyone gets in who has ever seen it —
    /// even from a mailbox nobody has emptied.
    public func endSharing(_ identifier: Profile.Identifier) async throws(CloudError) {
        guard let zone = ProfileMapping.zone(forItem: identifier) else {
            throw CloudError.other("Profile ID without a zone")
        }
        try await hub.endSharing(zone)
    }

    /// "Remove this profile from this device" for a **shared** profile.
    ///
    /// **Leaving is not deleting, and the order says so.** First the participation
    /// goes back at CloudKit, then the profile disappears from this device's book; the zone
    /// itself belongs to the other person and stays untouched. The other way round —
    /// deleting locally first — on an error the device would stay behind as a silent reader in
    /// a share that no longer appears in its UI.
    public func leave(_ identifier: Profile.Identifier) async throws(CloudError) {
        guard let zone = ProfileMapping.zone(forItem: identifier) else {
            throw CloudError.other("Profile ID without a zone")
        }
        try await hub.leave(zone)
        forget(identifier)
        var ledger = ProfileBook.read(from: store)
        ledger.remove(identifier)
        ledger.write(in: store)
    }

    /// Whether something under this code still lies in the public mailbox.
    ///
    /// **That is the feedback for the giving side.** Only the picker-up deletes the
    /// entry — if it is gone, someone picked it up. A receipt field of its own would be a
    /// second write operation in a **public** database, and from a
    /// device that does not own the zone at all.
    public func pairingExists(code: String) async throws(CloudError) -> Bool {
        guard let service = hub.service else { throw CloudError.noAccount }
        return try await service.readPublic(Pairing.name(forItem: code)) != nil
    }

    /// Empty the mailbox again if the screen closes before anyone has picked up.
    ///
    /// **A leftover entry is a valid key in a public
    /// database.** The five minutes catch it, but five minutes are five minutes —
    /// and whoever closes the screen has changed their mind.
    public func withdrawPairing(code: String) async throws(CloudError) {
        guard let service = hub.service else { return }
        try await service.deletePublic(Pairing.name(forItem: code))
    }

    /// The profile ID from a zone name (`profile-<uuid>`).
    static func identifier(from zone: ZoneID) -> Profile.Identifier? {
        guard zone.isProfile else { return nil }
        let raw = String(zone.name.dropFirst(ZoneID.preamble.count))
        guard let uuid = UUID(uuidString: raw) else { return nil }
        return Profile.Identifier(rawValue: uuid.uuidString)
    }
}
