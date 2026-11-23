import DesignSystem
import SwiftUI

/// An invisible hold for focus.
///
/// **This is the answer to "the sidebar keeps opening by itself".**
///
/// Whenever the view hierarchy is rebuilt, tvOS has to determine a new focus holder.
/// If it finds nothing focusable in the content area, it takes the next best thing it can
/// find — and in this app that is the sidebar: it sits in the same `HStack`
/// to the left, so it is the first child and geometrically the nearest target. It
/// then expands and pushes the content 232 points to the side.
///
/// This happens in **every** loading state, because none of them takes focus:
///
/// - The detail page shows only a spinner when it opens — that is why the sidebar opened
///   when a film was selected.
/// - The library shows only a spinner on the first switch to "Movies" as well,
///   and twice in a row: once while the library ID is fetched,
///   and once while its content loads.
/// - When going back from a detail page, the grid underneath is still empty for one pass,
///   because it is built lazily.
///
/// The viewer therefore does not see "the sidebar opens", but "the sidebar opens
/// and closes again" — a movement they did not trigger. Earlier fixes
/// **brought focus back** after it was gone; that shortens the bug but does not make
/// it invisible. Here it is prevented from arising at all.
///
/// ## Why not `defaultFocus` and not `prefersDefaultFocus`
///
/// Both say **which** of several targets is preferred. They do not help when there
/// is none at all — and that is the case here. A preference among zero candidates
/// has no effect, which has already cost an hour in this project.
///
/// ## Why it does no harm
///
/// The anchor is one point in size and transparent. It lives only while the state is loading;
/// as soon as there is real content it disappears, and focus moves there — the
/// view that sets it must make that transition itself. It cannot sensibly be selected,
/// but that does no harm either: it does nothing on press.
struct FocusAnchor: View {

    /// The name under which the view addresses it. Each view has its own name, so that
    /// two anchors visible at the same time do not take focus from each other.
    let id: String
    @FocusState.Binding var focus: String?

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .focusable()
            .focused($focus, equals: id)
            // Not a focus section and no highlight: it is meant to be found,
            // not seen.
            .accessibilityHidden(true)
    }
}

extension View {
    /// Puts an invisible focus anchor over this view — see ``FocusAnchor``.
    ///
    /// As an overlay and not as a sibling in the stack, because a spinner is usually
    /// centred and the anchor would otherwise shift its layout.
    func focusAnchor(_ id: String, focus: FocusState<String?>.Binding) -> some View {
        overlay(alignment: .topLeading) {
            FocusAnchor(id: id, focus: focus)
        }
    }
}
