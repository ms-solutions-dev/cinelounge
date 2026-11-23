import Core
import ProfileKit

/// **"Who's watching?" as a rule** — what a press on a circle does, which session
/// applies afterwards and which actions stand beside the profiles (G3, 2026-09-26).
///
/// **Finding B2 from the feature comparison:** On the TV "Who's watching?" showed profiles,
/// on the phone Jellyfin accounts — a profile without media server access was not
/// selectable there at all, and creating worked only on the TV ("Child profiles are created on the TV").
/// The computations for it were static functions in the TV's `AccountSwitcher`;
/// here they exist once, and both devices draw only their view above them.
///
/// **The switch itself is not here** — it belongs to ``ProfileKit/ProfileSwitch`` (latch,
/// session, header, pointer) and is called via ``ProfileManagement/switchTo(zu:pin:)``.
/// These computations only interpret its outcome.
public nonisolated enum ProfilePicker {

    /// What happens after a press on a circle.
    ///
    /// **A computation and no button body:** A sheet cannot be checked, a
    /// computation can. And the case at hand is one that cannot be seen on the screen
    /// — a press that is followed by nothing.
    public enum Reply: Equatable, Sendable {
        /// The switch worked; book, pointer and session are on the new person.
        case switched
        /// The target carries its own PIN — the number pad belongs in front of it.
        case pin
        /// Nothing to do: the same profile, or the switch failed.
        case nothing
    }

    public static func reply(to outcome: ProfileSwitch.SwitchOutcome) -> Reply {
        switch outcome {
        case .switched: .switched
        case .pinRequired, .wrongPin: .pin
        case .unknown, .unchanged: .nothing
        }
    }

    /// Which session applies after a switch — **`nil` means: none** (final check
    /// 2026-09-25, N-1).
    ///
    /// **Only a switched session is passed on.** After a switch to a
    /// profile without a media server, the Keychain would otherwise still hold the predecessor's session,
    /// and a child without an own account would see a parent's media library. ``ProfileKit/ProfileSwitch`` has cleared
    /// it since; here, in addition, what was not switched is not read.
    ///
    /// **`nil` is not a sign-out.** The wrapper then shows "no media server"; the
    /// access list stays there until someone switches back.
    public static func session(
        after result: ProfileSwitch.Outcome?,
        load: () -> ServerCredentials? = { try? SecureStore().loadCredentials() }
    ) -> ServerCredentials? {
        guard result?.didSwitchSession == true else { return nil }
        return load()
    }

    /// The circles behind the profiles — **in this order and independent of how many
    /// profiles there are.**
    ///
    /// **"Create profile" is always there** (owner decision 3 of 2026-09-25), even
    /// with three profiles and without an Apple account: Profiles are self-contained. A card that
    /// appeared only the first time would be a start screen under a different name.
    ///
    /// **"Add access" is no longer here** (AP59 N3, 2026-09-30): An access is
    /// a source and not a person; it belongs in Settings → Sources. In the sheet it
    /// always led to Jellyfin, even for someone who meant IPTV.
    public enum Action: String, CaseIterable, Sendable {
        case create = "anlegen"
        case manage = "verwalten"
    }

    /// The actions beside the profiles — **none when merely switching.**
    ///
    /// From the kids' interface and for a child profile there is no management
    /// (decision 20), **and a child does not create a profile**: A new profile would be one
    /// without a limit. The circles stay — the sheet is the only way out there.
    public static func actions(switchOnly: Bool) -> [Action] {
        switchOnly ? [] : Action.allCases
    }

    /// Whether a press on this circle triggers a switch at all — **the own profile
    /// does not.** A switch to itself would rewrite a session without changing anything.
    public static func triggers(_ target: Profile.Identifier, active: Profile.Identifier?) -> Bool {
        target != active
    }

    /// Whether "Who's watching?" stands before the media library at startup — **the same
    /// rule on both devices** (AP45 on the TV, since G3 on the phone too).
    ///
    /// ``ProfileKit/StartCurtain`` computes when nobody is fixed. **If parental controls
    /// apply, the curtain does not come:** A child who saw the circles would see an
    /// invitation; the way out then goes through the door with a PIN.
    public static func asksAtStart(_ gate: StartCurtain, protectionActive: Bool) -> Bool {
        gate == .whoIsWatching && !protectionActive
    }

    /// ``asksAtStart(_:protectionActive:)`` — **but only at the first start of this
    /// app run** (wrapper check H3, 2026-09-27).
    ///
    /// A rebuild caused by the app language of the selected profile is no start: On the phone
    /// and on the TV the question appeared a second time afterwards. The marker is
    /// ``Core/ProfilePointer/curtainIsDue()``, consumed even when the rule says no
    /// — the start is over.
    public static func asksNow(_ gate: StartCurtain, protectionActive: Bool) -> Bool {
        ProfilePointer.curtainIsDue()
            && asksAtStart(gate, protectionActive: protectionActive)
    }

    /// **No profile active although there are profiles: the question always comes** —
    /// whether the curtain of this run has been used or not (finding 2026-11-09).
    ///
    /// On the TV the app once stood in the main screen without an active profile after an
    /// install: the CL-Server was asked without a key, answered 401 for ten minutes, the
    /// sidebar lost it, and "Send request" did nothing — all three hang on the active
    /// profile. Without a person nothing personal works; the picker is the only right screen.
    public static func asksWithoutActive(
        active: Profile.Identifier?, profiles: Int, protectionActive: Bool
    ) -> Bool {
        active == nil && profiles > 0 && !protectionActive
    }
}
