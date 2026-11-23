import Core
import DesignSystem
import SwiftUI

/// The pill at the top edge: Home, Series, Movies, Home Videos.
///
/// **Built by hand and not as a second `TabView`.** The attempt to nest two section
/// pickers — the sidebar outside, the pill inside — was tested in a minimal example and
/// fails: tvOS does not show the inner bar at all. The outer one claims the spot for
/// itself.
///
/// Building it by hand has two advantages: the pill floats over the background image
/// instead of taking up space, and pressing left stays free for the sidebar — with a
/// real `TabView`, that movement would have switched to the tab on the left and never
/// reached the sidebar.
struct MediaTabBar: View {

    /// The sections of the media library. The app's sections, by contrast, live in the
    /// sidebar — two levels, not one long list.
    enum Section: String, CaseIterable, Identifiable {
        case home, series, movies, homeVideos

        var id: String { rawValue }

        /// The tab that shows a library kind — `nil` for kinds without a tab of their own
        /// (AP89: the jump from a Home shelf and the head of the library list).
        nonisolated init?(libraryKind: Core.Library.Kind) {
            switch libraryKind {
            case .series: self = .series
            case .movies: self = .movies
            case .homeVideos: self = .homeVideos
            default: return nil
            }
        }

        var titleKey: String {
            switch self {
            case .home: "tab.home"
            case .series: "tab.series"
            case .movies: "tab.movies"
            case .homeVideos: "tab.homeVideos"
            }
        }

        /// What the media library starts with. The default is the Home screen; `CINELOUNGE_START`
        /// can preset a different view so it can be checked without a remote.
        static var fromEnvironment: Section {
            Section(rawValue: ProcessInfo.processInfo.environment["CINELOUNGE_START"] ?? "")
                ?? .home
        }

        var symbol: String {
            switch self {
            case .home: "house"
            case .series: "tv"
            case .movies: "film"
            case .homeVideos: "person.2"
            }
        }
    }

    @Binding var selection: Section
    /// Held by the shell, not here: the Menu button in the grid must be able to lift the
    /// focus **into the pill** — so ``MainView`` has to be allowed to set it. Inside the
    /// pill this changes nothing, all accesses stay the same.
    @FocusState.Binding var focus: Section?

    /// Which sections actually show anything behind them.
    ///
    /// **Empty means "all"** — for previews and for the case that nothing is loaded yet. A
    /// screen that shows an empty pill on the first render and fills it half a second later
    /// flickers worse than one that carries one row too many.
    ///
    /// **Placed after the two bindings**, so the call in the shell stays readable in the
    /// order in which one says it: selection, focus, offering.
    var available: Set<Section> = []

    // MARK: - How much space it takes
    //
    // **These values exist because every view used to guess its own spacing.** The height
    // of the pill came from three places — font size, button padding, bar padding — and
    // was not tangible anywhere. Anyone who wanted to put something below it had to
    // calculate it or estimate it. On the Home screen a hand-picked 120 stands in for it;
    // in the library there was nothing at all, and that is why the grid ran through behind
    // the pill.

    static let barVerticalPadding: CGFloat = 9
    static let buttonVerticalPadding: CGFloat = 14

    /// The actual height of the capsule — **calculated, not copied.**
    static var height: CGFloat {
        TypeLevel.lineHeight(zu: TypeLevel.footer.points)
            + 2 * buttonVerticalPadding + 2 * barVerticalPadding
    }

    /// How far it stands off from the top edge of the screen. This is set in the frame, see
    /// ``MainView``.
    static let topInset: CGFloat = 20

    /// The gap between the capsule and the first content row — without it they stick to
    /// each other. A named value, because the library calculates its height budget against
    /// it: whatever grows here has to be subtracted there, and a copied 20 does not notice.
    /// See `LayoutBudgetTests`.
    static let stackGap: CGFloat = 20

    /// What a view has to leave free at the top so that its content begins **below** the
    /// pill instead of behind it.
    ///
    /// **Does not apply to the Home screen.** There the background image is meant to run up
    /// to the top edge of the screen with the pill floating over it; only the *text* in the
    /// header area keeps its distance.
    static var reservedTop: CGFloat { topInset + height + stackGap }

    /// Which sections belong to these libraries.
    ///
    /// **The mapping lives here and not in the shell**, because it belongs to the pill:
    /// whoever adds a fifth section should register it in one place.
    ///
    /// **`nonisolated`, and the release build forced that.** A `View` is `@MainActor` in
    /// Swift 6; the check passed in the debug build, and with `-O` it failed with
    /// "call to main actor-isolated static method in a synchronous nonisolated context".
    /// It is also correct on its merits: a pure calculation over a list, with no state and
    /// no UI — keeping it on the main thread would mean stopping the main thread to build a
    /// set.
    nonisolated static func sections(forItem libraries: [Core.Library]) -> Set<Section> {
        // **Empty means "not loaded yet" and not "nothing there."** Without this line the
        // function returned `[.home]`, and that is an *answer* — the fallback "empty means all"
        // in ``sections`` never kicked in. Result on the device on 2026-09-12: the Home screen
        // showed only "Start", although Series, Movies and Home Videos stood below it as
        // shelves.
        guard !libraries.isEmpty else { return [] }
        var found: Set<Section> = [.home]
        for library in libraries {
            switch library.kind {
            case .series: found.insert(.series)
            case .movies: found.insert(.movies)
            case .homeVideos: found.insert(.homeVideos)
            default: break
            }
        }
        return found
    }

    /// The sections that are shown.
    ///
    /// **An empty section is not shown** (2026-09-12). Here `Section.allCases` ran
    /// unfiltered: Home · Series · Movies · Home Videos always, even without a single
    /// home-video library. The sidebar, two files further on, writes down for itself why
    /// that is wrong — *"Without it there would be a row with four empty pages, and that
    /// looks like a bug, not like missing setup"* — and it hides the whole media library
    /// when there is no server. **Inside**, the four stayed fixed anyway; the same rule
    /// stopped at the doorstep.
    ///
    /// **Home always stays.** It is the section that carries the shelves, and those exist
    /// even without a media server — from portals, providers and the channel list. A pill
    /// that contracts to a single entry is then the correct information and not a loss.
    private var sections: [Section] {
        guard !available.isEmpty else { return Section.allCases }
        return Section.allCases.filter { $0 == .home || available.contains($0) }
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(sections) { section in
                button(for: section)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, Self.barVerticalPadding)
        // **Opaque, not translucent — and this is a correction.**
        //
        // This used to be `.ultraThinMaterial`, with the reasoning that the image behind it
        // should stay recognisable. On the TV it turned into something other than intended: the
        // background image blurs into the pill, and the two look as if they sat on the same
        // layer and had run into each other. Instead of "bar over image" one reads a smudge.
        //
        // Opaque, the image lies cleanly **underneath**. The original objection — an opaque
        // bar cuts off the header area at the top — only applies to a bar that takes up space.
        // This one floats: the image runs unchanged up to the top edge of the screen, and is
        // merely covered at this one spot instead of milky.
        .background(ColorRole.surface.color, in: Capsule())
        .overlay {
            Capsule()
                .stroke(ColorRole.text.color.opacity(0.08), lineWidth: 1)
                // **Must be pass-through.** An overlay lies above the content and takes part in
                // determining the focus target. This one line therefore covered the whole pill: the
                // focus landed on the first button but could not be moved left or right, because the
                // outline stood in between.
                .allowsHitTesting(false)
        }
        // The section takes the **full width**, the buttons stay centred.
        //
        // That is the reason the pill used to be reachable only from directly below it: tvOS
        // searches for the focus target geometrically. Anyone standing on "Play" at the bottom
        // left and pressing up finds nothing if the pill sits in the middle and does not
        // overlap horizontally. A section across the full width overlaps with everything below
        // it — the upward movement leads here from everywhere.
        .frame(maxWidth: .infinity)
        .focusSection()
        // **On entering, onto the tab one is standing on.**
        //
        // Without this, tvOS searches geometrically and lands on "Start", because that one
        // sits furthest left. Anyone pressing up from "Series" would first jump to a different
        // section — and because the pill switches as focus moves, the content changes right
        // along with it. So one does not reach the selection but ends up somewhere else.
        //
        // **`defaultFocus` and not `focusScope`.** A focus scope also restricts where the focus
        // may move — with it, tvOS found no way out of the bar into the content any more and
        // evaded to the sidebar, which then expanded. The initial focus can be specified
        // without this side effect.
        .defaultFocus($focus, selection)
        // **The section follows the focus, without anyone having to press.**
        //
        // That is how the providers do it on TV, and it is the difference between a bar and a
        // form: someone who moves from "Start" to "Series" wants to see series — they do not
        // want to move, then confirm, and confirm again when moving back. On the remote every
        // press is an effort.
        //
        // Pressing stays possible anyway: the button sets the same selection once more, which
        // changes nothing. A button that does not react to a press would be an irritation of
        // its own.
        //
        // Entering needs no special handling here any more: from outside only the active tab
        // is focusable — see ``button(for:)`` —, so every transition from `nil` onto a tab is
        // necessarily one onto the current selection, and the assignment changes nothing.
        .onChange(of: focus) { _, section in
            guard let section else { return }
            selection = section
        }
    }

    private func button(for section: Section) -> some View {
        let isActive = selection == section
        let isFocused = focus == section

        return Button {
            selection = section
        } label: {
            HStack(spacing: 12) {
                Image(systemName: section.symbol)
                Text(appKey: section.titleKey)
            }
            .font(TypeLevel.footer.font)
            .fontWeight(isActive ? .semibold : .regular)
            .foregroundStyle(foreground(isActive: isActive, isFocused: isFocused))
            .padding(.horizontal, 30)
            .padding(.vertical, Self.buttonVerticalPadding)
            .background(background(isActive: isActive, isFocused: isFocused), in: Capsule())
        }
        .bareFocusableButton()
        .focused($focus, equals: section)
        .info(appKey: section.titleKey, .chosen(isActive))
        // **From outside, only the active tab is a target.**
        //
        // tvOS picks the target of a movement geometrically, and from the grid upwards that
        // pointed at "Start" — the tab at the far left. Because the pill switches as focus
        // moves, the content changed right along with it: one wanted the selection and was
        // somewhere else. The earlier attempt corrected the focus **afterwards**
        // (`onChange`, only on `previous == nil`) — that ran behind the geometric decision and
        // was visible as a jump from "Start" to the active tab.
        //
        // That is why the decision is now made **before** tvOS rather than after it: as long
        // as the focus is outside the pill, the remaining tabs are disabled — the upward
        // movement cannot do anything but land on the active one. Once the focus is inside the
        // pill, all are back, and moving left and right works as before.
        //
        // **`disabled`, not `focusable` — and this was found out on the device.** At first
        // this was `.focusable(focus != nil || isActive)`, and with that the pill was no
        // longer reachable at all: `focusable(_:)` is meant for views that do not take focus
        // on their own; on a button it replaces its native focusability instead of making it
        // conditional — even with `true` no tab ever received the focus, and the press up
        // fizzled out. `disabled`, by contrast, demonstrably removes the button from the focus
        // search and leaves the active one untouched. Visually it changes nothing:
        // ``BareButtonStyle`` does not read the state, the colours come from their own
        // calculation.
        //
        // A `focusScope` would have been the obvious alternative and is not one: in the
        // earlier attempt it also restricted the movement **out of** the pill, and the focus
        // evaded to the sidebar.
        .disabled(!Self.isReachable(section, selection: selection, focus: focus))
    }

    /// The rule behind the disabling: from outside only the active tab is a focus target,
    /// inside the pill all of them are.
    ///
    /// Extracted so the test suite can pin it down — whether the pill is reachable at all
    /// depends on it. If it were `false` in both situations, there would be no way in; if
    /// it were `true` for all from outside, the press up would land geometrically on
    /// "Start" again.
    static func isReachable(_ section: Section, selection: Section, focus: Section?) -> Bool {
        focus != nil || section == selection
    }

    /// Three states, three colours — and they must differ clearly: at three metres'
    /// distance "selected" cannot otherwise be told apart from "focused", and one presses
    /// the wrong tab.
    private func foreground(isActive: Bool, isFocused: Bool) -> Color {
        if isFocused { return ColorRole.reason.color }
        return isActive ? ColorRole.text.color : ColorRole.textMatt.color
    }

    private func background(isActive: Bool, isFocused: Bool) -> Color {
        if isFocused { return ColorRole.text.color }
        return isActive ? ColorRole.text.color.opacity(0.14) : .clear
    }
}
