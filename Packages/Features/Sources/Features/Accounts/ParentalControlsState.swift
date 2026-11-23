import Core
import DesignSystem
import Foundation
import JellyfinKit
import ParentalControls
import ProfileKit
import SwiftUI

/// What the parental controls currently say on the TV — **in one place.**
///
/// **The rule itself lives in the shared package and not here.** ``ProtectionRule``
/// answers whether a door requires the PIN, whether a title may appear and whether a
/// section remains; this holder does nothing more than assemble it from
/// what is stored on **this** device — which account is signed in (G1), whether a
/// PIN has been set, whether the device as a whole is locked.
///
/// **Why this is a holder of its own and not a computed property.** The rule is
/// needed in many places and must not read differently in any of them. If it were built
/// at the call site, a new one would arise with every redraw — each with a trip to
/// the Keychain —, and two views could disagree about the same state. Exactly this kind
/// of disagreement was the most serious finding on the phone:
/// The lock claimed to lock what it did not lock.
///
/// **The pass lives here too.** A passed PIN applies to **one** door and
/// expires after two minutes (``Pass``); if it lived in a view, it would be gone
/// on leaving — and the next door would ask again, although it is the same action.
final class ParentalControlsState: ObservableObject {

    /// The rule in force. ``ProtectionRule/pending`` as long as nothing is locked.
    @Published private(set) var rule: ProtectionRule = .pending

    /// Which form factor the app has for the active profile (AP45, 2026-09-25).
    ///
    /// **Computed here and not in ``MainView`` from the profile model**, because it comes from
    /// the same profile book as the ``rule``: Two readers of the same book at
    /// different points in time could present a child with a child's limit and an
    /// adult's interface. This way both arise in one ``load()``.
    @Published private(set) var surface: Surface = .familiar

    /// The door for which the PIN is currently being asked. `nil` means no question is open.
    @Published var openQuestion: String?

    /// What Jellyfin says about the signed-in account. `nil` means **not yet
    /// asked** — and that is something different from "it says nothing".
    ///
    /// The difference decides what is on screen: a loading hint or
    /// the sentence "The server keeps no limit for this account."
    @Published private(set) var serverPolicy: ServerPolicy?

    private var doorGuard = DoorGuard()
    private let store: any KeyValueStore
    private let childAccounts: ChildAccountList
    private let childMode: ChildMode
    /// Where the profile book lives — the **file store** and not the Keychain.
    private let profileStore: any KeyValueStore

    /// **The same keys as in the phone project.** Both programs name the same
    /// thing the same; whoever later builds a sync between devices finds it under
    /// one name and not under two.
    ///
    // **And since 2026-09-20 "Block not-understood" no longer lives here either**
    // (AP40). Same reason, same trap: The key `childLock.blockUnknown`
    // was spelled out in both programs — here as `"1"` in the Keychain, on the
    // phone as a `Bool` in `UserDefaults`. Both directions now live in
    // ``ParentalControls/UnrecognizedLock``, including the default "yes".

    init(
        store: any KeyValueStore = SecureStore(),
        childAccounts: ChildAccountList = ChildAccountList(),
        profileStore: any KeyValueStore = FileStore(),
        childMode: ChildMode = ChildMode()
    ) {
        self.store = store
        self.childAccounts = childAccounts
        self.profileStore = profileStore
        self.childMode = childMode
        load()
    }

    /// Reassembles the rule.
    ///
    /// To be called after every change that touches one of its ingredients: account switch, PIN
    /// set or deleted, device lock toggled.
    ///
    /// **The computation lives in the shared package** (AP58 R1, finding K2,
    /// ``ParentalControls/RuleBuilder``) — limit, lock and assignments per profile with
    /// the device floor, the account kind from profile kind OR old account list, the allow list
    /// only on a child. Here it only reads who is sitting in front and which account is
    /// signed in. The reasons for the individual ingredients (AP22, AP41, AP45, strand G)
    /// are given there.
    func load() {
        let signedIn = (try? SecureStore().loadCredentials()).map(Account.Identifier.init)
        let active = ProfileBook.read(from: profileStore).activeProfile
        surface = Surface.forItem(active)
        rule = RuleBuilder.rule(
            profile: active?.identifier.rawValue, profileIsChild: active?.kind == .kind,
            accountIsChild: signedIn.map { childAccounts.isChild($0.stored) } ?? false,
            deviceLocked: childMode.on, from: store)
    }

    /// The limit in force — for the interface.
    var limit: AgeLimit? { rule.limit }

    /// Sets the age limit. `nil` takes it back.
    ///
    /// **Taking back means deleting and not "set to 18".** "From 18" is a level
    /// that locks something; "no limit" is the absence of the question. Whoever merged the two
    /// could not say afterwards what had been set.
    func set(limit incoming: AgeLimit?) {
        AgeLimit.write(incoming, in: store)
        load()
    }

    /// The **own** limit of a profile — without the device floor (AP45, Decision 7).
    ///
    /// **Not ``limit``**, which shows the one in force, that is, the stricter of profile and
    /// device. Whoever edits a child profile wants to see what is set **on it**;
    /// the one in force would show a number they did not set there, and if they changed
    /// it, they would end up writing the floor into the profile.
    func ownLimit(forItem profile: String) -> AgeLimit? {
        AgeLimit.read(from: store, forItem: profile)
    }

    /// Sets the limit **of a profile** — the path that was missing until 2026-09-24.
    ///
    /// **Why it is needed:** ``set(limit:)`` writes to the **device**, and the
    /// only screen for it knew no profile. What ``ProfileKit/ProfileBackup`` had once
    /// copied into the child profiles stayed there and was unchangeable afterwards. The
    /// open question "for whom does one configure?" was answered by a product decision: **on the
    /// child profile itself** — that is, where an adult edits it.
    ///
    /// **The store is the same as when reading** (``ParentalControls/RuleBuilder``). That is the
    /// point where this path almost went wrong early on 2026-09-24: A
    /// limit written somewhere other than where it is read looks like
    /// "nothing set" — for parental controls, a silent opening.
    func set(limit incoming: AgeLimit?, forItem profile: String) {
        AgeLimit.write(incoming, in: store, forItem: profile)
        load()
    }

    /// The allow list for channels **of a profile** (AP52).
    func channelApproval(forItem profile: String) -> ChannelApproval {
        ChannelApproval.load(from: store, forItem: profile)
    }

    /// Stores the allow list of a profile and re-reads the rule.
    ///
    /// **The same store as when reading in ``load()``** — the lesson from 2026-09-24 on
    /// ``set(limit:forItem:)`` applies here just the same.
    func set(channelApproval incoming: ChannelApproval, forItem profile: String) {
        incoming.save(to: store, forItem: profile)
        load()
    }

    /// Schaltet, ob Unverstandenes sperrt.
    func set(blocksUnrecognized fresh: Bool) {
        UnrecognizedLock.write(fresh, in: store)
        load()
    }

    // MARK: - Doors

    /// Whether this door opens now — **and consumes a valid pass in doing so.**
    ///
    /// **Checking and consuming in one call, and that is intentional.** ``Pass``
    /// separates the two explicitly, because a view is evaluated several times and a
    /// checking consume would be a trap there. Here is the place where *action* is
    /// taken — a key press, exactly one —, and therefore both belong together.
    ///
    /// - Returns: `true` if it may proceed. Otherwise the question is in
    ///   ``openQuestion`` and the view shows the sheet.
    func isAllowed(finished door: String) -> Bool {
        guard !doorGuard.passesThrough(door, rule: rule) else { return true }
        openQuestion = door
        return false
    }

    /// Whether the content behind this door currently has to be **covered** — and consumes
    /// nothing in doing so.
    ///
    /// **The separation from ``isAllowed(finished:)`` is the whole point of this package** (AP23,
    /// 2026-09-11). The door sits at the **action** — a key press, exactly one —,
    /// and there checking-and-consuming is right. The section in the settings
    /// follows **focus** (`SettingsView.swift:294-358`), however, without any
    /// check: Whoever wanders through the section list has pressed nothing.
    ///
    /// **The obvious remedy was to call ``isAllowed(finished:)`` there, and it is
    /// wrong.** ``Pass`` expires on use; called on every focus change,
    /// every wander downwards would pull up the PIN sheet, the wrap-around at the end of the list
    /// likewise, and the remembered section already on opening. The section list would be
    /// unusable in child mode.
    ///
    /// **So: the door stays at the action, the curtain hangs on focus.** This
    /// question may be asked as often as you like — also several times per redraw, as
    /// SwiftUI does.
    ///
    /// **A passed pass lifts the curtain without consuming it.** Whoever has entered the
    /// PIN sees the content for the lifetime of the pass
    /// (``Pass/lifetime``) — and not just for the blink of an eye until the next
    /// evaluation clears it away again.
    func isHidden(_ door: String) -> Bool {
        doorGuard.isHidden(door, rule: rule)
    }

    /// Asks for the PIN for this door, **without opening anything that is already open.**
    ///
    /// For the button on the curtain: It should show the sheet, not consume the pass
    /// that it may just have obtained itself.
    func queryPending(_ door: String) {
        guard isHidden(door) else { return }
        openQuestion = door
    }

    /// The reason shown on the sheet — **a separate one per door.**
    ///
    /// "Not allowed" explains nothing; whoever stands before a locked door wants to
    /// know what lies behind it and why it is protected.
    func reason(forItem door: String) -> String? {
        LockedDoors.reason(door)
    }

    /// Accepts an entered PIN.
    ///
    /// - Returns: `true` if it is correct. Then the door stands open, and the next
    ///   ``isAllowed(finished:)`` for the **same** door goes through — for another door it does not.
    @discardableResult
    func verify(_ digits: String) -> Bool {
        guard let door = openQuestion,
            doorGuard.open(door, using: digits, pin: Pin(store: store))
        else { return false }
        openQuestion = nil
        return true
    }

    /// Cancels the question without opening anything.
    func cancel() {
        openQuestion = nil
    }

    // MARK: - What the server says

    /// Fetches the user policy of Jellyfin.
    ///
    /// **Read out and shown, not trusted** — the core sentence of this package, and it
    /// already stands that way in ``JellyfinSource`` (l. 1385). The server filters more reliably
    /// than any app: It does not hand out locked titles in the first place. In return it knows nothing
    /// of Xtream, nothing of the portals and nothing of this device. **Two filters
    /// that want the same thing are not a mistake** — whoever relied on the server alone
    /// would have no limit at all for three of four sources.
    ///
    /// **That is why nothing is switched off here.** The information does not change the rule;
    /// it **explains** it. Whoever is missing titles on the TV that appear
    /// in the web interface otherwise looks in the wrong program.
    ///
    /// `userPolicy()` has always existed and was called by nobody — the information
    /// was retrievable and was never fetched.
    func loadPolicy(from source: JellyfinSource) async {
        guard let accessPolicy = try? await source.userPolicy() else { return }
        serverPolicy = ServerPolicy(
            // **A number becomes raw text**, because ``ServerPolicy`` carries it
            // that way: What the server writes is as little standardized as what is in the
            // files, and both are interpreted through the same path
            // (``ApprovalInterpretation``). Passing a number through here would mean building a second
            // interpretation for the server.
            maximumRating: accessPolicy.maximumRating.map(String.init),
            isRestricted: accessPolicy.disabled,
            blockedCatalogs: accessPolicy.blockedCatalogs)
    }

    // MARK: - Setting

    /// Whether these digits are the PIN in force — **without opening a door.**
    ///
    /// Separate from ``verify(_:)``: There it is about a pass, here about a
    /// proof. Whoever changes the PIN has not opened a door by doing so.
    func matchesPin(_ digits: String) -> Bool {
        Pin(store: store).matches(digits)
    }

    /// Sets a new PIN.
    ///
    /// **Only afterwards does anything apply at all.** ``ProtectionRule/applies`` requires a
    /// PIN to be set — without it the locked doors are open and the filter
    /// permeable, and intentionally so: A lock without a way back would be a trap.
    func setPin(_ digits: String) {
        guard Pin(store: store).set(digits) else { return }
        load()
    }

    /// Resets the parental controls as a whole — **the way out.**
    ///
    /// **Not just the PIN.** If the device lock stayed in place, the device would after the
    /// reset still be in child mode, only without a key — exactly the trap that the
    /// rule "only with PIN" protects against.
    func clearPin() {
        Pin(store: store).delete()
        childMode.set(false)
        load()
    }

    /// Toggles the device lock.
    ///
    /// **It applies to the device and not to an account.** An Apple TV in the children's room
    /// is locked no matter who is signed in; a child account on the other hand brings its limit
    /// everywhere. ``ProtectionRule/applies`` takes both paths, and one
    /// suffices.
    func setDeviceLock(_ on: Bool) {
        childMode.set(on)
        load()
    }
}
