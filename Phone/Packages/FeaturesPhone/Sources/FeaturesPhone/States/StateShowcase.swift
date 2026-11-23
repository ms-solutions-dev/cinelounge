import DesignSystemPhone
import Flows
import Foundation
import SwiftUI

/// Play through all states in one place.
///
/// **For development only, and checked in anyway.** Nineteen states that one otherwise
/// only sees with the network cable pulled, an expired access token or an occupied
/// provider account are otherwise never checked — and the three mistakes made
/// there are always the same: a sentence appears twice, a button lies
/// outside the thumb zone, and an empty case looks like a broken one.
///
/// **Each one sits in the head of its host view, with the tab bar that belongs to it.**
/// That is no decoration: "This library is empty" on its own on a black ground looks like
/// a failure and under the large title "My Library" like an information message. Whoever checks the
/// states on a list of their own checks them in a place where they never
/// appear — exactly the mistake ``BarProbe`` has already avoided once with the
/// tabs.
///
/// The bar shows **all** tabs here, because a situation with all sources is the only one
/// in which every host occurs.
///
/// - Note: Not deleted. The reason the showcase exists does not go away
///   when AP21 brings the set-up — on the contrary: then there are more states and
///   not fewer.
struct StateShowcase: View {

    @State private var chosen: PlaybackPhase = Self.start

    /// What the showcase opens with — from `CINELOUNGE_ZUSTAND`, otherwise the first one.
    ///
    /// **Without it the showcase can only be checked by hand.** The simulator accepts no
    /// tap commands from outside; whoever wants to document nineteen states without tapping
    /// nineteen times themselves needs a way to call each one individually.
    /// Same pattern as `CINELOUNGE_SPIELER` for the player.
    private static var start: PlaybackPhase {
        PlaybackPhase(rawValue: ProcessInfo.processInfo.environment["CINELOUNGE_ZUSTAND"] ?? "")
            ?? .loadingStart
    }

    /// All sources set up — otherwise the Live and Portals tabs are missing, and
    /// with them six of the nineteen hosts.
    private let state = CatalogState.fromAccesses(
        jellyfin: true, channelList: true, portals: true, downloads: true, provider: true)

    private var allStates: [PlaybackPhase] { PlaybackPhase.onPhone }

    private var number: Int { (allStates.firstIndex(of: chosen) ?? 0) + 1 }

    var body: some View {
        TabView(selection: tabSelection) {
            ForEach(state.tabs) { tab in
                SwiftUI.Tab(value: tab) {
                    // **Every tab shows the same thing**, because the selection carries the state
                    // along: only the selected one is visible anyway.
                    hostView
                } label: {
                    Label {
                        Text(appKey: tab.titleKey)
                    } icon: {
                        Image(systemName: tab.icon.zu(active: tab == chosen.host.tabs))
                    }
                    .environment(\.symbolVariants, .none)
                }
            }
        }
        .tint(ColorRole.brandLight.color)
        .background(ColorRole.reason.color)
    }

    /// The tab bar **leads** here instead of just watching.
    ///
    /// **Finding from 2026-09-05, seen in the simulator: a black screen.** The first
    /// version bound the selection to `.constant` and showed an empty surface for every other
    /// tab. iOS switches the bar anyway — a selection that cannot be
    /// set does not hold the finger back. So whoever tapped "Home" landed on
    /// nothing, and that looks like a crash.
    ///
    /// Now a press on a tab jumps to the **first state of this host**. That
    /// is incidentally the better operation: paging through nineteen states one by one to
    /// see the three portal cases was the detour.
    private var tabSelection: Binding<Tab> {
        Binding(
            get: { chosen.host.tabs ?? .library },
            set: { tabs in
                if let first = allStates.first(where: { $0.host.tabs == tabs }) {
                    chosen = first
                }
            })
    }

    /// The screen on which this state really sits.
    private var hostView: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                controlPanel
                LargeTitle(title: chosen.hostTitle)
                    .padding(.horizontal, MetricsBoard.phone.margin)

                // knopflos: **The showcase shows states, it does not act.** It demonstrates
                // all nineteen, including those whose action only makes sense on its own
                // screen — "reload" without a catalog behind it
                // would be a mere claim here. This is the **only** place in the project
                // with an empty body, and `scripts/buttons.py` demands the same justification for every
                // further one.
                StateView(state: chosen, action: {})

                if chosen == .portalFetchAddress {
                    StepwiseFallback(probe: .fallbackViaBridge)
                        .padding(.bottom, MetricsBoard.phone.section)
                }

                if chosen.form == .muted {
                    // The silent state has nothing else to show — and that is exactly
                    // its content. Without this line the showcase would look like a bug in the showcase
                    // at this spot.
                    Footnote(wording: Self.silentHint)
                        .padding(.horizontal, MetricsBoard.phone.margin)
                        .frame(maxHeight: .infinity, alignment: .center)
                }
            }
        }
    }

    /// Forward, back, and the list — **at the top**, because below the state itself is operated.
    private var controlPanel: some View {
        HStack(spacing: MetricsBoard.phone.gutter) {
            Button {
                page(-1)
            } label: {
                Image(systemName: Glyph.back.name)
            }
            .accessibilityLabel(Text(verbatim: "Previous state"))

            Menu {
                ForEach(allStates) { state in
                    Button(state.rawValue) { chosen = state }
                }
            } label: {
                Text(verbatim: "\(number)/\(allStates.count) · \(chosen.rawValue)")
                    .font(TypeLevel.label.font)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)

            Button {
                page(1)
            } label: {
                Image(systemName: Glyph.next.name)
            }
            .accessibilityLabel(Text(verbatim: "Next state"))
        }
        .foregroundStyle(ColorRole.textMatt.color)
        .padding(.horizontal, MetricsBoard.phone.margin)
        .frame(height: Metrics.target)
    }

    private func page(_ step: Int) {
        guard let now = allStates.firstIndex(of: chosen) else { return }
        // Wrapping around: whoever plays through the showcase does not want to run into a dead key at the
        // end, but to arrive at the front again.
        let target = (now + step + allStates.count) % allStates.count
        chosen = allStates[target]
    }

    /// Deliberately without a language catalog: the showcase is a tool and is never translated.
    private static let silentHint = """
        Nothing is shown here on purpose. The fetch was interrupted by an incoming call — \
        that is not a server problem. The old catalog stays in place, the status line says \
        how old it is, and the next wake-up quietly catches up.
        """
}
