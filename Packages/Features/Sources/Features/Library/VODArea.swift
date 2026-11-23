import Core
import DesignSystem
import PlaylistKit
import SwiftUI

/// Films and series of **one** channel list.
///
/// **The area answers two questions, and therefore has two controls**
/// (draft `design/movies-allSeries.html`, 2026-08-22): the switch at the top chooses the
/// **kind** — films or series —, the button next to it the **genre**. The bar
/// on the left only answers **which list**.
///
/// Why the kind needs its own switch and does not appear as two entries in
/// the bar: Xtream keeps films and series in **separate genres with their
/// own numbering**. A flat list could not carry both, and three
/// levels in the bar (list → kind → genre) would mean three presses on the TV
/// before the first poster.
struct VODArea: View {

    /// The genres of this list, both kinds mixed — they are separated here.
    let libraries: [Core.Library]
    /// How the area builds its grid for a genre.
    let content: (Core.Library) -> AnyView
    /// The way back into the sidebar.
    var onLeaveToSidebar: () -> Void = {}

    /// Welche Art gerade gilt. Gemerkt je Liste — siehe ``VODMemory``.
    @State private var kind: Core.Library.Kind = .movies
    /// Which genre currently applies. `nil` means "the first of this kind".
    @State private var categoryID: String?
    @State private var showsChooser = false
    @FocusState private var focus: String?

    private static let switchID = "vod.kind."
    private static let chooserID = "vod.chooser"
    /// The anchor of the window — see ``chooser``.
    private static let anchorID = "vod.sheet.anchor"

    /// The genres of the current kind, provider decorations removed.
    private var categories: [Core.Library] {
        libraries.filter { $0.kind == kind }
    }

    /// Which kinds this provider carries at all.
    ///
    /// **A switch with one side is not a switch.** Whoever has stored only films
    /// should not see a "Series" tab that leads nowhere.
    private var availableKinds: [Core.Library.Kind] {
        [.movies, .series].filter { kind in libraries.contains { $0.kind == kind } }
    }

    private var current: Core.Library? {
        categories.first { $0.id == categoryID } ?? categories.first
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ColorRole.reason.color.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                header
                if let current {
                    // **The identifier makes the view identity, and a silent bug
                    // hung on it** (seen in the simulator, 2026-08-22):
                    // ``LibraryView`` holds its model as a `@StateObject`, and
                    // its build instruction runs **once per identity**. Without
                    // `id` the view is structurally the same after switching —
                    // SwiftUI keeps the old model, and the grid kept showing the
                    // genre from before while the header already named the
                    // new one. No error, no message, just wrong
                    // content.
                    content(current)
                        .id(current.id)
                } else {
                    Spacer()
                }
            }

            if showsChooser { chooser }
        }
        .ignoresSafeArea(edges: [.top, .bottom, .trailing])
        // **Back leads into the sidebar, not out of the app.**
        // ``onLeaveToSidebar`` has been there as a parameter since this view was built
        // and was passed by all four call sites in ``MainView`` —
        // nobody ever called it. Whoever is in the **header** of this area (the
        // kind buttons, the categories button) therefore had no catcher in the
        // response chain, and the menu button went to the system. The same picture as with the
        // on-device finding of 2026-08-16: "when I'm in the list and click back,
        // it jumps out of the app".
        //
        // The catcher sits at the root node of this view and not at the
        // embedding in ``MainView`` — there it would lie outside the
        // ``NavigationStack`` and never get its turn in the response chain.
        .onExitCommand(perform: onLeaveToSidebar)
        .onAppear(perform: restore)
        .onChange(of: kind) { _, _ in
            // **The genre applies per kind.** On switching, the old identifier points
            // to a genre of the other kind — it must be discarded, otherwise the
            // grid would stay empty although genres exist.
            categoryID = VODMemory.category(forProvider: providerID, kind: kind)
            VODMemory.setKind(kind, forProvider: providerID)
        }
        .onChange(of: categoryID) { _, id in
            guard let id else { return }
            VODMemory.setCategory(id, forProvider: providerID, kind: kind)
        }
    }

    /// The list this area belongs to — read from the identifier.
    private var providerID: String {
        libraries.first.flatMap { XtreamVODSource.parseLibraryID($0.id)?.playlistID } ?? ""
    }

    private func restore() {
        let stored = VODMemory.kind(forProvider: providerID)
        kind = availableKinds.contains(stored) ? stored : (availableKinds.first ?? .movies)
        categoryID = VODMemory.category(forProvider: providerID, kind: kind)
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 26) {
            if availableKinds.count > 1 {
                HStack(spacing: 8) {
                    ForEach(availableKinds, id: \.self) { option in
                        kindButton(option)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, MediaTabBar.barVerticalPadding)
                .background(ColorRole.surface.color, in: Capsule())
                .focusSection()
            }

            if categories.count > 1 {
                chooserButton
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, MetricsBoard.tv.margin)
        .padding(.top, TVMetrics.topMargin)
        .padding(.bottom, 22)
    }

    /// **Exactly the calculation of the tab pill** (``MediaTabBar``) — and that is
    /// why it looked inconsistent here before (user finding 2026-08-22).
    ///
    /// With `.buttonStyle(.plain)` tvOS lays its **own** focus plate over the
    /// button: a white, raised field that takes the padding along and
    /// bulges beyond the capsule in the process — on the neighboring tab it visibly lay
    /// on top. ``bareFocusableButton()`` removes this field; foreground and
    /// background come from the same calculation as up in the library,
    /// so both switches of the app look the same.
    private func kindButton(_ option: Core.Library.Kind) -> some View {
        let isActive = kind == option
        let isFocused = focus == Self.switchID + option.rawValue

        return Button {
            kind = option
        } label: {
            Text(app: option == .series ? "tab.series" : "tab.movies")
                .font(TypeLevel.footer.font)
                .fontWeight(isActive ? .semibold : .regular)
                .foregroundStyle(
                    isFocused
                        ? ColorRole.reason.color
                        : (isActive ? ColorRole.text.color : ColorRole.textMatt.color)
                )
                .padding(.horizontal, 30)
                .padding(.vertical, MediaTabBar.buttonVerticalPadding)
                .background(
                    isFocused
                        ? ColorRole.text.color
                        : (isActive ? ColorRole.text.color.opacity(0.14) : .clear),
                    in: Capsule()
                )
        }
        .bareFocusableButton()
        .focused($focus, equals: Self.switchID + option.rawValue)
    }

    /// The genre button, at the same height and with the same focus color as
    /// the switch next to it — **a capsule, not a rectangle**: two
    /// corner radii side by side read as two different things.
    private var chooserButton: some View {
        let isFocused = focus == Self.chooserID

        return Button {
            showsChooser = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "square.grid.2x2")
                Text(app: "vod.category.choose")
                Image(systemName: "chevron.down")
                    .font(TypeLevel.lowercased.font)
            }
            .font(TypeLevel.footer.font)
            .fontWeight(.semibold)
            .foregroundStyle(isFocused ? ColorRole.reason.color : ColorRole.text.color)
            .padding(.horizontal, 30)
            .padding(.vertical, MediaTabBar.buttonVerticalPadding)
            .background(
                isFocused ? ColorRole.text.color : ColorRole.text.color.opacity(0.14),
                in: Capsule()
            )
        }
        .bareFocusableButton()
        .padding(.vertical, MediaTabBar.barVerticalPadding)
        .focused($focus, equals: Self.chooserID)
        // Two characters around a text: "grid, choose genre, arrow down".
        .info(appKey: "vod.category.choose")
    }

    // MARK: - The selection window

    /// **Closed off like the filmography window** (user directive 2026-08-22):
    /// focus stays inside, the way back is the menu button.
    ///
    /// The three parts that achieve this are the same as in
    /// ``FilmographySheet`` — and none can be dropped:
    ///
    /// 1. An **anchor** that holds the focus as long as the list has none yet.
    /// 2. `onExitCommand` **on the panel**, not on the frame around it.
    /// 3. A **guard**: if the focus slips outside, it brings it back.
    ///
    /// Without the guard the window loses the menu button along with the focus —
    /// which then goes to the navigation and closes the page underneath or
    /// the app outright (finding of 2026-08-11).
    @ViewBuilder
    private var chooser: some View {
        ColorRole.reason.color.opacity(0.74)
            .ignoresSafeArea()
            .onExitCommand(perform: closeChooser)

        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { scroller in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(categories) { library in
                            categoryRow(library)
                                .id(library.id)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .onAppear {
                    guard let id = current?.id else { return }
                    focus = "vod.cat." + id
                    scroller.scrollTo(id, anchor: .center)
                }
            }
        }
        .frame(width: 760)
        .padding(.horizontal, 30)
        .padding(.vertical, 34)
        .background(ColorRole.surface.color, in: RoundedRectangle(cornerRadius: 28))
        .padding(.leading, 186)
        .padding(.vertical, 96)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .focusSection()
        .focusAnchor(Self.anchorID, focus: $focus)
        .onExitCommand(perform: closeChooser)
        // **The guard.** `nil` does not mean "no focus" but "the focus
        // is outside" — behind the window or in the sidebar. Exactly
        // there the window loses the menu button.
        .onChange(of: focus) { _, current in
            guard showsChooser, current == nil else { return }
            focus = Self.anchorID
        }
    }

    private func categoryRow(_ library: Core.Library) -> some View {
        Button {
            categoryID = library.id
            closeChooser()
        } label: {
            HStack(spacing: 18) {
                Image(systemName: "folder")
                    .foregroundStyle(
                        focus == "vod.cat." + library.id
                            ? ColorRole.reason.color
                            : (library.id == current?.id
                                ? ColorRole.brandLight.color : ColorRole.textQuiet.color))
                Text(ChannelName.display(library.name))
                    .lineLimit(1)
                Spacer(minLength: 12)
            }
            .font(TypeLevel.text.font)
            .foregroundStyle(
                focus == "vod.cat." + library.id
                    ? ColorRole.reason.color : ColorRole.text.color
            )
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .background(
                focus == "vod.cat." + library.id
                    ? ColorRole.text.color
                    : (library.id == current?.id ? ColorRole.surfaceHigh.color : .clear),
                in: RoundedRectangle(cornerRadius: 12)
            )
        }
        .bareFocusableButton()
        .focused($focus, equals: "vod.cat." + library.id)
        .info(
            Text(ChannelName.display(library.name)), .chosen(library.id == current?.id))
    }

    private func closeChooser() {
        showsChooser = false
        // Back onto the button that opened the window — otherwise tvOS picks
        // something itself, and that sits somewhere in the grid.
        focus = Self.chooserID
    }
}
