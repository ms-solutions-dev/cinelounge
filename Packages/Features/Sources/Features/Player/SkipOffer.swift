import Core
import DesignSystem
import Flows
import SwiftUI

/// The button for skipping a section.
///
/// Bottom right and only inside the reported window, as in the template.
/// **Not a permanent element on screen:** a button that is always there stands around
/// pointlessly in every film without an intro, and in the living room it then gets clicked because it
/// is simply there. Whether the window applies is decided by ``PlayerModel/skipOffer`` — this
/// view only knows the section.
struct SkipOffer: View {

    let segment: MediaSegment
    /// After skipping by itself (AP85): the same button says "Intro skipped · Back" and
    /// jumps to the start of the section.
    var isUndo = false
    @FocusState.Binding var focus: String?
    let onSkip: () -> Void

    @Environment(\.accentPalette) private var palette

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                button
            }
        }
        .padding(.trailing, MetricsBoard.tv.margin)
        .padding(.bottom, 112)
    }

    private var button: some View {
        let isFocused = focus == "skip"

        return Button(action: onSkip) {
            // **Slim, as next to the next-episode card** (variant B, 2026-11-09): until then
            // headline type at 74 points — the largest element on the screen for a button
            // that only says "skip".
            HStack(spacing: 12) {
                Image(systemName: isUndo ? "arrow.uturn.backward" : "forward.end.fill")
                Text(appKey: label)
            }
            .font(TypeLevel.footer.font)
            .fontWeight(.semibold)
            .foregroundStyle(isFocused ? ColorRole.text.color : ColorRole.reason.color)
            .padding(.horizontal, 26)
            .frame(height: 56)
            .background(isFocused ? Color(palette) : ColorRole.text.color, in: Capsule())
        }
        .bareFocusableButton()
        .focused($focus, equals: "skip")
        .focusHighlight(isFocused, scale: Tokens.Focus.buttonScale, accent: Color(palette, .bright))
        .info(appKey: label)
    }

    private var label: String {
        isUndo ? PlaybackWording.undoSkip(segment.kind) : Self.labelKey(for: segment.kind)
    }

    /// The label names the section.
    ///
    /// "Skip" alone would be ambiguous: at the end of an episode the button stands for
    /// the credits, at the start for the intro, and in series with a recap for
    /// something you might want to see. The cases that ``MediaSegment`` does not
    /// offer for skipping do not arrive here.
    /// **Shared since AP58 R4** (``Flows/PlaybackWording``) — the phone has the same
    /// button.
    static func labelKey(for kind: MediaSegment.Kind) -> String {
        PlaybackWording.skip(kind)
    }
}
