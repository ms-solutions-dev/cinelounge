import Core
import Foundation

/// The profiles of this device and the one currently watching.
///
/// **The replacement for ``Core/AccountState`` and `SetupState`** (AP41). Both
/// answered the same question — "what is set up here?" — and both answered
/// it **for the device**. As long as only one person sat in front of it, that was the same; as soon as there
/// are two, it is wrong: one person's channel list was the child's, and a
/// account switch changed the media server and nothing else.
///
/// **The store follows the rule from AP40:** a profile is structure, hence a file
/// (``Core/FileStore``, written via ``Core/RecordSheet``). Passwords and
/// access tokens stay in the Keychain — only **whom** they belong to is stored here.
///
/// **What this book is not: a sign-in.** Switching a profile does not mean
/// signing out. On the TV that was the only way until 2026-09-06, and it took along the
/// snapshots per library, the Top Shelf token and the image stock. Whoever switches
/// changes an identifier here; nothing else is touched.
public struct ProfileBook: Sendable {

    /// All profiles of this device, in the order in which they were created.
    public private(set) var profile: [Profile]

    /// Who is currently watching. `nil` as long as nothing is set up.
    ///
    /// **An identifier and not the profile itself.** Keeping two copies of the same profile
    /// side by side means forgetting one of them at some point — exactly the
    /// mistake that ``AccountsModel`` deliberately separated with "list and signed-in session side by side"
    /// and that this type does not repeat.
    public private(set) var active: Profile.Identifier?

    public init(profile: [Profile] = [], active: Profile.Identifier? = nil) {
        self.profile = profile
        // **An identifier that does not exist is not a selection.** It would arise when
        // removing the active profile — and the UI would then show an empty
        // circle instead of a person.
        self.active = profile.contains { $0.identifier == active } ? active : profile.first?.identifier
    }

    // MARK: - Fragen

    /// The profile that is currently watching.
    public var activeProfile: Profile? {
        profile.first { $0.identifier == active }
    }

    /// Whether a switch is offered at all.
    ///
    /// As a question of its own and not as `profile.count > 1` at the call site: a
    /// single profile is not half a switch but none at all.
    public var canSwitch: Bool { profile.count > 1 }

    /// What is set up on this device for the **active** profile.
    ///
    /// **The replacement for ``Core/AccountState``, and the reasoning from there still applies:**
    /// three independent flags and explicitly not an enumerated type. Whoever starts with a
    /// channel list and later adds the media server must not have to start
    /// over — with flags adding is an assignment, with an enumeration
    /// a conversion at every use site.
    ///
    /// **Without a profile the state is empty and not "unknown".** A fresh device has
    /// nothing set up; that is an answer and not the absence of one.
    public var state: Situation {
        Situation(activeProfile)
    }

    /// What is set up for a person.
    public struct Situation: Sendable, Equatable {

        /// Whether an access to a media server is stored.
        public let hasMediaServer: Bool

        /// Whether at least one channel list is stored.
        ///
        /// **Stored, not switched on** — the sentence comes from ``Core/AccountState``
        /// and migrated along because its reason did: whoever temporarily switches off their only list
        /// would otherwise be offered the setup again, as if
        /// the typed-in access were lost. On tvOS typing is the most expensive
        /// operation; this scare must not occur.
        public let hasChannelList: Bool

        /// Whether the portals are wanted.
        public let wantsPortals: Bool

        init(_ profile: Profile?) {
            hasMediaServer = profile?.jellyfin != nil
            hasChannelList = !(profile?.channelLists.isEmpty ?? true)
            wantsPortals = profile?.wantsPortals ?? false
        }

        public init(
            hasMediaServer: Bool = false, hasChannelList: Bool = false,
            wantsPortals: Bool = false
        ) {
            self.hasMediaServer = hasMediaServer
            self.hasChannelList = hasChannelList
            self.wantsPortals = wantsPortals
        }

        /// Whether anything is set up yet at all.
        ///
        /// If not, the start belongs to the choice between the paths — and
        /// not to the sign-in at a media server. Whoever has a purchased channel list
        /// would otherwise take the app for the wrong program.
        public var isSetUp: Bool { hasMediaServer || hasChannelList || wantsPortals }

        /// Whether the library appears. All its areas come from the media server;
        /// without it there would be empty pages, and that looks like an error.
        public var showsLibrary: Bool { hasMediaServer }

        /// Whether the Live area appears.
        public var showsLive: Bool { hasChannelList }

        /// Whether the UI should offer adding a media server later.
        ///
        /// As a question of its own and not as `!hasMediaServer` at the use site: an
        /// area that is simply omitted looks broken. Where something is missing,
        /// the way to it must be there — the same condition, only with the opposite intent.
        public var offersMediaServer: Bool { !hasMediaServer }
    }

    // MARK: - Changing

    /// Adds a profile. **The first one also becomes the active one.**
    ///
    /// Otherwise after setup there would be a device with one profile that nobody
    /// is sitting in front of — and the first question would be a choice from one.
    ///
    /// **Only the first, not every one on an empty "aktiv"** (check 2026-09-25 evening): after
    /// ``clearActive()`` every sync adds profiles anew to the book (``ProfileCloud/download(_:)``);
    /// otherwise the next arrived profile would move up — even one with a PIN.
    public mutating func create(_ profileName: Profile) {
        let first = profile.isEmpty
        profile.removeAll { $0.identifier == profileName.identifier }
        profile.append(profileName)
        if active == nil, first { active = profileName.identifier }
    }

    /// Removes a profile.
    ///
    /// **If it was the active one, the first moves up** — without asking for its PIN. Whoever
    /// has to send the successor through the latch empties afterwards with ``clearActive()``.
    public mutating func remove(_ identifier: Profile.Identifier) {
        profile.removeAll { $0.identifier == identifier }
        if active == identifier { active = profile.first?.identifier }
    }

    /// Nobody is sitting in front of it anymore — **the book stands without an active profile.**
    ///
    /// **For the successor of a removed profile that has to pass the latch** (check
    /// 2026-09-25 evening): ``remove(_:)`` lets the first move up, even if it carries a
    /// PIN, and then it would be active in the book without anyone having entered it.
    /// Whoever does not want that empties here and looks for the successor via
    /// ``ProfileSwitch/switchTo(zu:in:keychain:deviceStore:ledgerStore:pin:)`` — the
    /// path that ``StartChoice/apply(in:keychain:deviceStore:ledgerStore:)`` also
    /// takes. If none gets through without a PIN, it stays empty, and that is the case
    /// "Who is watching?" (``StartCurtain/forItem(startTarget:active:profile:)``).
    public mutating func clearActive() {
        active = nil
    }

    /// Switches the active profile.
    ///
    /// **An unknown profile does not become active**, and that is not an error that anyone
    /// would have to catch: the only way there is an identifier from an outdated
    /// view, and that should not change anything.
    public mutating func switchTo(zu identifier: Profile.Identifier) {
        guard profile.contains(where: { $0.identifier == identifier }) else { return }
        active = identifier
    }

    /// Changes an existing profile in place.
    ///
    /// **Via a block and not via a replacement from outside.** Whoever fetches the profile,
    /// changes it and writes it back has it twice in between — and when writing back
    /// silently overwrites an intermediate change.
    public mutating func update(_ identifier: Profile.Identifier, _ block: (inout Profile) -> Void) {
        guard let slot = profile.firstIndex(where: { $0.identifier == identifier }) else { return }
        block(&profile[slot])
    }

    /// A moved media server — **every profile that has it moves along** (E3).
    ///
    /// The account list is keyed by address and user; a profile that still carries the old
    /// address would find no account at the next switch, and
    /// ``ProfileSwitch`` would empty the session.
    ///
    /// - Returns: how many profiles were rewritten.
    @discardableResult
    public mutating func moveServer(from old: URL, after fresh: URL) -> Int {
        var count = 0
        for slot in profile.indices where profile[slot].moveServer(from: old, after: fresh) {
            count += 1
        }
        return count
    }

    // MARK: - Ablage

    /// **One key, one file** — the same form as with ``Core/ShelfOrder``.
    public static let key = "profiles"

    /// What is in the file.
    ///
    /// **A type of its own and not ``ProfileBook`` itself being `Codable`.** The book carries
    /// rules (the first becomes active, an unknown one does not); a generated
    /// `init(from:)` would bypass them and could produce a state that no
    /// method can produce.
    private struct Content: Codable, Equatable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case profile
            case active = "aktiv"
        }

        var profile: [Profile]
        var active: String?
    }

    /// Reads the book.
    ///
    /// **An empty "aktiv" stays empty**, even if profiles are in it: only
    /// ``clearActive()`` writes that, and if, as in the initializer, the first were allowed to move up here,
    /// the profile with a PIN would stand in front again at the next read.
    public static func read(from store: any KeyValueStore) -> ProfileBook {
        guard let content = RecordSheet.read(Content.self, under: key, from: store)
        else { return ProfileBook() }
        var ledger = ProfileBook(
            profile: content.profile, active: content.active.map(Profile.Identifier.init(rawValue:)))
        if content.active == nil { ledger.clearActive() }
        return ledger
    }

    /// Writes the book — **and deletes the file when no profile is in it anymore.**
    public func write(in store: any KeyValueStore) {
        guard !profile.isEmpty else {
            RecordSheet.cleanUp(Self.key, in: store)
            return
        }
        RecordSheet.write(
            Content(profile: profile, active: active?.rawValue), under: Self.key, in: store)
    }
}
