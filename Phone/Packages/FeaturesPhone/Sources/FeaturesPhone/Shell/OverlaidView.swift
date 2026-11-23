import DesignSystemPhone
import SwiftUI

/// What lies above the tab bar: setup, accounts, parental controls, settings.
///
/// They **cover** the bar and do not replace it — hence a full screen and no
/// further tab. An overlay is left with "Done", and that clears the whole
/// stack, not one step: whoever is finished from the third level of the settings
/// does not want to go back twice.
///
/// **A guided stack and no longer just the topmost view (2026-09-07).** Until then
/// `NavigationStack { content(overlay.last) }` stood here — a stack without `path:` that
/// swapped its whole content at every step. Three things were missing as a result, and
/// all three were flagged in review as "rigid and dated":
///
/// * **No place for a title.** `navigationTitle` occurred zero times in the whole project —
///   not out of negligence but because there was no view it could hang on.
///   Whoever stood three levels deep (Account → Accounts → Certificates) read nowhere where
///   they were.
/// * **No push transition.** The content jumped instead of sliding.
/// * **No swipe back from the edge.** You had to aim at the top left — with the thumb, against
///   the second of the five rules in `GESTALTUNG.md` §4. The tabs have always been able to
///   (``ShellModel/path(forItem:)``); the overlay was the only stack of the app that
///   was none.
///
/// **The root is the first overlay and not an empty screen.** A
/// `NavigationStack` needs a root; here it is the view that opened the overlay
/// — otherwise an empty surface would flash up on opening before the first push comes.
///
/// The toolbar uses `.cancellationAction` and `.confirmationAction` instead of
/// `.topBarLeading` and `.topBarTrailing`. That is not only platform-neutral — it also says
/// what the two buttons **are**, and iOS places them left and
/// right by itself.
///
/// **"Back" no longer exists as a button of its own.** The `NavigationStack`
/// now draws it itself, with the title of the previous level next to it — that is more information than a
/// bare arrow symbol ever had. What remains is "Done", and here that still means: clear
/// the whole overlay.
struct OverlaidView<Content: View>: View {

    let navigator: Navigator
    let parentalControls: ParentalControlsState
    @ViewBuilder let content: (ViewID) -> Content

    /// The path **above** the root — the stack does not carry the root itself.
    private var route: Binding<[ViewID]> {
        Binding(
            get: { Array(navigator.overlay.dropFirst()) },
            set: { fresh in navigator.overlay = Array(navigator.overlay.prefix(1)) + fresh })
    }

    var body: some View {
        NavigationStack(path: route) {
            if let root = navigator.overlay.first {
                named(root)
                    // **The destination belongs IN the stack and not on it** — the bug from
                    // E42, reported on 2026-09-07 on the device: tapping Settings anywhere
                    // always leads to this screen, a black screen with a
                    // yellow triangle.
                    //
                    // The caller hung ``navigationDestination(for:destination:)`` on the
                    // `NavigationStack` **itself** instead of on its content. SwiftUI looks for the
                    // destination inside the stack, though; attached outside it is
                    // **silently ignored**, and every step ends on the
                    // placeholder "no destination found" — exactly the yellow triangle.
                    //
                    // **It reports itself, but nowhere anyone looks.** The
                    // compiler is silent, every check stays green, and the sentence stands
                    // only in the system log: "There's a misplaced
                    // navigationDestination(for:destination:) modifier for type
                    // Ansichtskennung. It will be ignored." Since the same day
                    // `scripts/run.sh` reads out these messages after the start.
                    .navigationDestination(for: ViewID.self) { view in
                        named(view)
                    }
            }
        }
        // **The accent colour and not the system blue.** Seen on screen on 2026-09-06:
        // "Done" stood in blue — the iOS default, which appears everywhere
        // an app sets none of its own. In an app whose entire board is calculated and
        // checked against the contrast thresholds, an unchecked foreign colour is
        // the one place that falls out of line — and it stands precisely on the
        // button everybody presses.
        .tint(ColorRole.brandLight.color)
        // As long as an overlay lies there, it is the topmost level — see ``LockedDoor``.
        .lockedDoor(navigator, state: parentalControls, isResponsible: true)
    }

    /// A view with its title and its "Done".
    ///
    /// **The title comes from ``ViewID/titleKey`` and not from the
    /// view.** It would otherwise stand in twenty-one files, and at the twenty-second
    /// it would be missing — the same consideration that puts the gatekeeper in one place.
    ///
    /// **Narrow and not large** — the reasoning is at
    /// ``DesignSystemPhone/SwiftUICore/View/narrowTitle()``. The root is the
    /// exception: it carries its large title in the content.
    @ViewBuilder
    private func named(_ view: ViewID) -> some View {
        if let title = view.titleKey {
            content(view)
                .navigationTitle(Text(appKey: title))
                .narrowTitle()
                .toolbar { done }
        } else {
            content(view)
                .toolbar { done }
        }
    }

    /// **On every level and not only on the root.** "Done" clears the whole overlay;
    /// whoever had it only at the top would have to tap up from the third level first in order to
    /// get out — exactly what the explanation above rules out.
    private var done: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button {
                navigator.done()
            } label: {
                Text(app: "common.done")
            }
        }
    }
}
