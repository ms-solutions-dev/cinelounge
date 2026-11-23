import DesignSystemPhone
import SwiftUI

/// A scroll area with the way back to the top.
///
/// **A building block and not a special solution for the detail page** (user decision
/// of 2026-09-05: scrolling up should actually be possible everywhere and always). Every
/// long list in this app has the same problem — Home with six shelves, a grid with
/// a hundred and three posters, a series with fifty episodes. Whoever solves it in one
/// place has it still open in three; whoever solves it here has also solved it in
/// Live, Portals and Search before they are built.
///
/// **It replaces `ScrollView` and does not wrap it.** An extra modifier that can be forgotten
/// gets forgotten — and then the way to the top is missing exactly on the screen that
/// was added last. Whoever writes `ScrollView` here sees from the name that they have
/// chosen something different.
struct ScrollSurface<Content: View>: View {

    /// How far the button floats above the safe area.
    ///
    /// **Measured from the safe area and not from the screen edge.** The tab bar is
    /// already included as the bottom safe-area inset in this scroll area, and an
    /// `overlay` is placed inside it and not beneath it. Until 2026-09-07 this used
    /// ``Metrics/bottomInset`` — the same 83 points a second time. Measured on screen: The
    /// button sat **165 instead of 20 points** above the tab bar and so floated in the
    /// middle of the content.
    ///
    /// **That is why the default is a margin and not a bar height.** What is at the
    /// bottom, the safe area knows better than a number: under a presented screen only the
    /// home indicator, in a tab the bar, in the library additionally the sort row, which
    /// hangs there via `safeAreaInset`. Only whoever stacks their bar alongside instead of
    /// hooking it in has to add it — the detail page does that, see
    /// ``Metrics/aboveFloatingBar``.
    let bottomClearance: CGFloat

    /// Whether the content runs up under the status bar (header image of the detail page).
    let edgelessTop: Bool

    /// The **identifier of the topmost visible row** — optional, and kept outside.
    ///
    /// **Why, finding of 2026-09-09:** *Going into clips and then back, it always jumps straight
    /// to the top and I have to scroll down again.* When descending into a portal layer,
    /// the view changes branch — a folder list becomes a grid —, SwiftUI tears down this
    /// `ScrollView` and builds a new one on return. What it kept privately is then gone.
    ///
    /// **On the morning of 2026-09-09 a `Binding<ScrollPosition>` stood here, and it could not
    /// work.** The reason is in black and white in the SDK interface:
    /// `ScrollPosition.init(idType:)` defaults to `Never.self`, and `viewID` returns an
    /// instance of exactly this type. `Never` has no instance — a place built this way
    /// **can** therefore never carry an identifier, only an offset, and nobody can
    /// restore an offset on an area that does not exist yet. ``PortalsModel`` returned
    /// exactly such a `ScrollPosition()` for an unknown layer; with that, the type of the
    /// whole binding was fixed from the first assignment. The checks for it were green
    /// because in the test they put in `ScrollPosition(id:)` — that is, the case the view
    /// never produced.
    ///
    /// **That is why now a string and not a foreign construct.** What is remembered is the
    /// identifier of a row; whoever holds it can check it, store it and put it back
    /// without having to know anything about SwiftUI.
    ///
    /// **Default `nil` means: The scroll area keeps its position itself.** The thirty
    /// remaining callers stay unchanged; only whoever needs it to survive passes in a
    /// handle.
    ///
    /// **What the caller has to do for this:** Their rows need `.id(…)` with a
    /// **string**, and the body a `.scrollTargetLayout()`. Without both,
    /// ``SwiftUI/View/onScrollTargetVisibilityChange(idType:threshold:_:)`` reports
    /// nothing, and then the old behavior remains — nothing breaks, nothing is just
    /// remembered.
    let location: Binding<String?>?

    let content: Content

    /// **`ScrollPosition` instead of an anchor in the content.** The earlier way was an
    /// invisible element at the very top that `scrollTo` targets — that is one more element
    /// in every list, just so one button works. Since iOS 18 the scroll area itself can
    /// jump to its edge.
    ///
    /// **It is set in `init` and not in `onAppear`.** A freshly built area thereby already
    /// carries the jump target in its first build; a `ScrollViewReader` would have to act
    /// in `onAppear` for that, and whether its `scrollTo` hits a `LazyVStack` that is only
    /// just being created is exactly the bet on which this morning's version failed. A
    /// place with an identifier, by contrast, is an **order** that SwiftUI carries out as
    /// soon as it has laid out the row.
    @State private var ownPosition: ScrollPosition
    @State private var isFarDown = false

    /// Counts every request "to the top" — see ``SwiftUI/EnvironmentValues/scrollToTopRequest``.
    @Environment(\.scrollToTopRequest) private var scrollToTopRequest

    /// From what fraction a row counts as visible — **almost zero, on purpose.**
    ///
    /// The default of `onScrollTargetVisibilityChange` is one half. With that, the topmost
    /// row, which is always only partly in view, would **not** be the first one reported
    /// but the second — and because on return the position is anchored at its top edge,
    /// the list would slide down one row further with every round trip. With a hair as the
    /// threshold, the remembered row is the same one that stands at the top after the
    /// jump, and the position stays put.
    private static var countsAsVisible: Double { 0.01 }

    /// In which bottom corner the "to the top" button sits.
    ///
    /// **Because two targets do not fit in the same corner** (AP7, 2026-09-23). The A–Z
    /// ``JumpBar`` holds a grip strip of `Metrics.target` (44 points) at the right edge
    /// and lies in the `ZStack` above this area — it wins hit testing there, and a tap on
    /// the middle of the button jumped to the letter "Z". Stacking order does not solve
    /// this: If the button lay on top, it would cover "X", "Y", "Z".
    ///
    /// **The default is the right corner**, because four of five views have no bar and the
    /// button belongs where the hand is. That the fifth does not forget it is guarded by
    /// ``jumpBarAndButtonShareNoCorner()`` — a view that draws bar and area together
    /// and leaves this corner alone turns red.
    private let scrollToTopCorner: Alignment

    init(
        bottomClearance: CGFloat = MetricsBoard.phone.margin, edgelessTop: Bool = false,
        location: Binding<String?>? = nil, scrollToTopCorner: Alignment = .bottomTrailing,
        @ViewBuilder content: () -> Content
    ) {
        self.bottomClearance = bottomClearance
        self.edgelessTop = edgelessTop
        self.scrollToTopCorner = scrollToTopCorner
        self.location = location
        self.content = content()
        _ownPosition = State(
            initialValue: location?.wrappedValue.map { ScrollPosition(id: $0, anchor: .top) }
                ?? ScrollPosition(idType: String.self))
    }

    var body: some View {
        ScrollView {
            content
        }
        .scrollPosition($ownPosition)
        // **The offset is measured, only the yes or no is remembered.** The offset changes on
        // every frame; writing it into state would mean rebuilding the whole page sixty times
        // a second while you swipe.
        .onScrollGeometryChange(for: Bool.self) {
            $0.contentOffset.y > ScrollToTopButton.fromHeight
        } action: { _, fresh in
            isFarDown = fresh
        }
        // **The topmost visible row is recorded explicitly.** Relying on `.scrollPosition`
        // to write its identifier back into the binding by itself was this morning's defect;
        // here, instead of an assumption, there is a callback that does only one thing and
        // whose result the caller can check.
        //
        // **No target, no report.** If the list reports nothing, the last remembered row
        // stays — an empty report also arrives when the area is torn down, and adopting it
        // would mean deleting the position exactly as you leave.
        .onScrollTargetVisibilityChange(
            idType: String.self, threshold: Self.countsAsVisible
        ) { visible in
            guard let location, let topmost = visible.first else { return }
            location.wrappedValue = topmost
        }
        .overlay(alignment: scrollToTopCorner) {
            ScrollToTopButton(isVisible: isFarDown) {
                withAnimation(Motion.expand) {
                    ownPosition.scrollTo(edge: .top)
                }
            }
            .padding(scrollToTopCorner == .bottomLeading ? .leading : .trailing, MetricsBoard.phone.margin)
            .padding(.bottom, bottomClearance)
        }
        .ignoresSafeArea(edges: edgelessTop ? .top : [])
        // **The double tap on the selected tab** (AP7). The native bar does not report it
        // as an event — it calls the selection's setter once more with the same value, and
        // whoever is not watching hears nothing. ``ShellView`` watches and counts up; here
        // the number arrives.
        //
        // **Passed through the environment and not through the views.** Between the bar and
        // this area lie, depending on the tab, two to four views that have nothing to do
        // with scrolling; having each of them carry a number onward would mean touching four
        // files for one gesture — and forgetting the fifth with the next tab.
        .onChange(of: scrollToTopRequest) { _, _ in
            withAnimation(Motion.expand) { ownPosition.scrollTo(edge: .top) }
        }
    }
}

extension EnvironmentValues {

    /// A counter that counts up on every request "to the top".
    ///
    /// **A number and not a `Bool`.** Double-tapping the same tab twice would otherwise
    /// give the same value the second time as the first, and nothing would happen —
    /// the same consideration as with the haptics counter in ``TileCommands``.
    ///
    /// **It is set where the bar sits** (``ShellView``), and read in every
    /// ``ScrollSurface`` below it. That areas which are currently not in view scroll along
    /// too has no consequence: They are at the start anyway or are rebuilt at the next
    /// appearance.
    @Entry public var scrollToTopRequest: Int = 0

    /// Whether large amounts of data are acceptable on the current network path — from
    /// ``NetworkStatus/NetworkPath/largeVolumesAcceptable``.
    ///
    /// **Through the environment, because two sheets need the same information and neither
    /// of them has a network guard.** ``DownloadSheet`` is created once from the detail page
    /// and once from the tab placeholder; threading the path there twice would mean
    /// maintaining two places, one of which gets forgotten with the next sheet.
    ///
    /// **Default `true`**, so "acceptable": Whoever has no information should not be
    /// downgraded a step. A precaution without a measurement is a degradation without
    /// reason.
    @Entry public var largeVolumesAcceptable: Bool = true
}
