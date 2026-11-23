import DesignSystemPhone
import Flows
import SwiftUI

/// A state as it really sits on the screen: the block in the middle, the
/// one loud button at the bottom in the thumb zone.
///
/// **This is the place where the rule from `GESTALTUNG.md` §4 is kept.** Everything
/// that is pressed often sits at y = 560 or below, or floats above the bottom edge — "without
/// exception". For a failure message the one button is even the only thing that can be
/// pressed; putting it in the middle of the screen would be the worst place
/// of all.
///
/// **An information message gets no bar here.** It demands nothing — a floating bar
/// over a sentence that only explains something would be a button without a job.
struct StateView: View {

    let state: PlaybackPhase

    /// The one next step — **not optional, and that is the whole decision.**
    ///
    /// **Direction K5a from 2026-09-06: the text was not the problem, the type was.**
    /// As long as `(() -> Void)?` stood here, everyone forgot it: eleven call sites, **two**
    /// with an action, **zero** with a secondary action. ``StateBlock`` drew an outline
    /// and chevron around a button that did nothing. `ShellView` spells out the rule itself
    /// — "a button that leads nowhere is worse than none" —, and an optional value overrides
    /// it without anyone noticing.
    ///
    /// **Even a state without a loud button demands it.** Whoever shows an information message knows
    /// today what the next step would be if it ever gets one — and has to write it
    /// down instead of supplying it later. Where there really is none (the
    /// ``StateShowcase``), an empty body stands **with a justification**, and
    /// `scripts/buttons.py` demands exactly that.
    ///
    /// **Since AP58 R3 it applies only to the targets of the call site** (``StateRoute``): "try
    /// again" and the system settings. If the job leads elsewhere — to the account, to
    /// the channel lists — the button goes through the shell's ``Navigator``; until then it
    /// only reloaded at this site, under every label.
    let action: () -> Void

    /// The quiet path next to it — mostly "meanwhile to the downloads".
    ///
    /// **Stays optional, but is drawn only if it is there.** Whether a state has a second
    /// path at all, it says itself (``StateInfo/sidePath``); whether anyone handles it is
    /// said by the call site. If the handler is missing, ``StateBlock`` draws no button —
    /// instead of drawing one that stays silent.
    var secondaryAction: (() -> Void)?

    /// The path to the downloads that the shell sets once — see ``OpenDownloadsKey``.
    @Environment(\.openDownloads) private var openDownloads

    /// The shell's path for the targets of the ``Navigator`` — see ``StateRoute``.
    @Environment(\.stateRoute) private var stateRoute

    /// **What the loud button really does — or `nil`, then there is none.**
    ///
    /// A target of the call site is handled by `action`, a target of the ``Navigator`` by the
    /// environment value. If that is missing (outside the shell), the button stays away: a button
    /// that promises to lead to the account and then reloads would tell an untruth.
    private var primaryRoute: (() -> Void)? {
        guard let target = state.form.target else { return nil }
        if StateRoute.belongsToPlace(target) { return action }
        guard let stateRoute else { return nil }
        return { stateRoute(target) }
    }

    /// **What the quiet button really does.**
    ///
    /// An explicitly passed action wins: it is the call site's answer to **this**
    /// state, and that knows more than a rule. If it is missing and the secondary path leads to the
    /// downloads, the environment value steps in — so the six states get their path
    /// without fourteen call sites each supplying it separately.
    private var secondaryRoute: (() -> Void)? {
        if let secondaryAction { return secondaryAction }
        guard state.sidePathLeadsToDownloads, let openDownloads else { return nil }
        return { openDownloads() }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            StateBlock(form: state.form, secondaryAction: secondaryRoute)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let button = state.form.loudButton, let primaryRoute {
                FloatingBar {
                    Button {
                        primaryRoute()
                    } label: {
                        Text(appKey: button).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.loud)
                }
            }
        }
    }
}
