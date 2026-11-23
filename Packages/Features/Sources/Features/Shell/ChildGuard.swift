import Combine
import Core
import DesignSystem
import Flows
import ParentalControls
import ProfileKit
import SwiftUI

/// Keeps the layout of the shell in step with the active profile (AP45, 2026-09-25).
///
/// **Two tasks, and both were missing.**
///
/// * **Re-read after a switch.** ``ParentalControlsState`` read the profile book when
///   building the shell and never again; ``MainView`` claimed in its DocC that it is
///   rebuilt on an account switch. But a `@StateObject` survives every new
///   parameter list — and a switch to a profile on the same media server does not even change that.
///   Whoever switched from the adult to the child kept the adult's rules and
///   interface.
/// * **No destination outside the layout.** The sidebar shows a child four entries, but
///   not every path goes through the sidebar: The button of a ``PlaybackPhase`` ("Go to
///   Settings") sets the destination directly. Here every destination is checked against
///   ``ParentalControls/ChildScope/isAllowed(_:)``; what is not listed there leads to the Library.
///   **Also for the first frame:** The shell may start on an area that a child
///   does not have — the one last remembered by the adult on the same device.
///
/// **And when leaving Settings, ``MainView`` re-reads both** — the profile list
/// there keeps its own ``ProfileModel``, and a switch there does not reach ``active`` here.
/// Without that, the layout of the previous profile would stay until the app restarts.
///
/// **A separate modifier and not two `onChange` in the body of the shell** — that body is bound by
/// the compiler's computation budget, and every further chain there is the one it gives up on.
///
/// **The third task: discard standing paths** (cross-check AP45, 2026-09-25, B4).
/// The navigation path of the shell was cleared only by "Home". If on a switch the
/// detail page of an 18-rated film was open, it stayed open for the child, and "Play" on it
/// no longer asked any filter. When the ``RuleState`` changes, the guard calls ``discard``;
/// the shell clears the path and re-marks its content with the same state, so that
/// the models of search and favorites fall with their old filter.
///
/// **The fourth: also hear what comes from afar** (final review 2026-09-25, C2-5).
/// ``active`` is a value from ``ProfileModel``, and that reads its book only when someone asks it
/// to. If another device moves the active profile into another one
/// (move note), ``ProfileKit/ProfileMove`` switches book and ``Core/ProfilePointer`` —
/// but nobody asked the shell to re-read, and a child sat until the next occasion under
/// the rules of a profile that no longer existed. ``ProfileKit/ProfileCloud/arrival`` was meant for this
/// and wired up nowhere. The guard now listens to both notifications
/// (``Core/ProfilePointer/switched``, ``ProfileKit/ProfileCloud/arrived``) and re-reads;
/// whatever changes in the ``RuleState`` as a result, it discards like any other switch.
///
/// **And the session follows** (track F, 2026-09-25). Only rules and
/// profiles were re-read; if the target of a move lay on another media server or on none,
/// the Library of the old account stayed up. ``reread`` therefore calls
/// ``ProfileModel/loadAfterArrival()`` in the shell — rationale there.
struct ChildGuard: ViewModifier {

    let active: Profile.Identifier?
    let surface: Surface
    /// The rule in force — it belongs to the ``RuleState``.
    var rule: ProtectionRule = .pending
    @Binding var destination: AppSidebar.Destination
    let reread: () -> Void
    /// What falls on a new ``RuleState`` — the path and the destination of the shell.
    var discard: () -> Void = {}

    /// **Everything that a built model or an open path hangs on.**
    ///
    /// **The profile alone is not enough:** A child's limit can change
    /// without anyone switching, and a PIN that is set later turns a
    /// rule that does not apply into one that does. **The rule alone is not enough either:**
    /// Two adults without a lock have the same rule, but different paths.
    struct RuleState: Hashable {
        let active: Profile.Identifier?
        let surface: Surface
        let rule: ProtectionRule
    }

    var state: RuleState { RuleState(active: active, surface: surface, rule: rule) }

    /// The notifications after which it re-reads — see the fourth task above.
    static let notifications: [Notification.Name] = [ProfilePointer.switched, ProfileCloud.arrived]

    /// Both notifications as one stream, **on the main thread**: ``reread`` touches
    /// `@StateObject`s.
    static var fromRemote: AnyPublisher<Notification, Never> {
        Publishers.MergeMany(notifications.map { NotificationCenter.default.publisher(for: $0) })
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    /// Whether a change from `old` to `fresh` discards the open paths — **every** change
    /// of the state does. An exception for "stricter is harmless" would exist only at
    /// the price of a second computation, and a path that starts again at
    /// the Library after a switch costs nobody anything.
    static func discardsDestination(from old: RuleState, zu fresh: RuleState) -> Bool {
        old != fresh
    }

    /// Where the shell leads after discarding — **to where it is heading anyway, if
    /// the layout allows it** (final review 2026-09-25, A2-1).
    ///
    /// **The finding:** ``discard`` always set the destination to the Library. The new
    /// ``RuleState`` is only read when you leave Settings — and
    /// Settings are left with a press in the sidebar. Whoever pressed "Live" after a change to
    /// parental controls stood in the Library afterwards. What must be discarded is the
    /// **path** (open detail pages, the tab of the Library); the destination only if
    /// the new profile does not have it.
    ///
    /// **With the rule** (AP52): Whether "Live" is allowed for a child is decided by their
    /// allow list — and that is in the rule, not in the layout.
    static func target(
        afterDiscarding destination: AppSidebar.Destination, rule: ProtectionRule
    ) -> AppSidebar.Destination {
        rule.scope.isAllowed(destination) ? destination : .media
    }

    /// Which area of Settings a ``ActionTarget`` leads to — or `nil`
    /// if it is none **or the layout has no Settings** (cross-check
    /// AP45, K1).
    ///
    /// The guard underneath did bring a child back to the Library, but only after
    /// Settings had been built for one frame. Here they are not led there in the first place.
    static func settingsArea(
        forItem target: ActionTarget, rule: ProtectionRule
    ) -> SettingsSection? {
        guard rule.scope.isAllowed(.settings) else { return nil }
        switch target {
        case .accounts, .setup: return .account
        case .channelLists: return .playlists
        case .liveSettings: return .live
        case .portalSettings: return .portals
        case .retry, .sync, .certificate, .downloadRules, .systemSettings: return nil
        }
    }

    func body(content: Content) -> some View {
        content
            .onAppear {
                if !rule.scope.isAllowed(destination) { destination = .media }
            }
            .onChange(of: active) { _, _ in reread() }
            .onReceive(Self.fromRemote) { _ in reread() }
            // **On the whole state and not just the layout** (AP52): If a child's
            // allow list is emptied, the rule changes and not the
            // layout — and "Live" must give way anyway.
            .onChange(of: state) { old, fresh in
                if Self.discardsDestination(from: old, zu: fresh) { discard() }
                if !fresh.rule.scope.isAllowed(destination) {
                    destination = .media
                }
            }
            .onChange(of: destination) { _, fresh in
                if !rule.scope.isAllowed(fresh) { destination = .media }
            }
    }
}
