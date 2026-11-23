import DesignSystem
import Flows
import ProfileKit
import SwiftUI

/// The frame of A5, the IPTV sheet and A6 — **head, content, and the room around them.**
///
/// The sheets are complete screens of their own (with background), so that the setup can show
/// them inline or as a cover without a frame of its own around them.
struct SetupSheetFrame<Content: View>: View {

    /// "Lea · Jellyfin" — the product name is never translated.
    let title: String
    var stage: SetupStepHead.Stage = .sources
    @ViewBuilder let content: Content

    var body: some View {
        ZStack(alignment: .topLeading) {
            ColorRole.reason.color.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                SetupStepHead(stage: stage, title: title)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 48)
            }
            .padding(.horizontal, MetricsBoard.tv.margin)
            .padding(.vertical, TVMetrics.topMargin)
        }
    }
}

/// The head of every setup screen after A2: **three marks for "Profile · Sources · Done"** and
/// the name of the step (design A of 2026-11-15) — **one head for A3 to A7**, so that the marks
/// stand in the same place on every page.
///
/// The sheets of A4 (Jellyfin, IPTV, CL-Server) all belong to the middle step.
struct SetupStepHead: View {

    /// The three steps the marks count.
    nonisolated enum Stage: Int, CaseIterable, Sendable {
        case profile
        case sources
        case done
    }

    /// How one mark is drawn.
    nonisolated enum Mark: Equatable, Sendable {
        /// A step behind — filled, quiet.
        case passed
        /// The step now — long and in the brand's light.
        case current
        /// A step ahead — only its place.
        case ahead
    }

    var stage: Stage = .sources
    /// "Lea · Jellyfin" — the product name is never translated.
    let title: String

    /// The marks of a stage, from the left.
    nonisolated static func marks(at stage: Stage) -> [Mark] {
        Stage.allCases.map { step in
            step.rawValue < stage.rawValue ? .passed : step == stage ? .current : .ahead
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(Self.marks(at: stage).enumerated()), id: \.offset) { _, mark in
                self.mark(mark)
            }
            Text(verbatim: title)
                .font(TypeLevel.footer.font)
                .foregroundStyle(ColorRole.textMatt.color)
                .padding(.leading, 10)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: title))
    }

    private func mark(_ mark: Mark) -> some View {
        Capsule()
            .fill(fill(mark))
            .frame(width: mark == .current ? 44 : 14, height: 14)
    }

    private func fill(_ mark: Mark) -> Color {
        switch mark {
        case .passed: ColorRole.textMatt.color
        case .current: ColorRole.brandLight.color
        case .ahead: ColorRole.surface.color
        }
    }
}

/// The buttons of the sheets — **one main path, the rest quieter**, as in the old sign-in.
struct SetupButton: View {

    enum Rank {
        case main
        case beside
    }

    let title: LocalizedStringKey
    var rank: Rank = .beside
    let identifier: String
    let focus: FocusState<String?>.Binding
    let action: () -> Void

    private var isFocused: Bool { focus.wrappedValue == identifier }

    var body: some View {
        Button(action: action) {
            Text(app: title)
                .font(rank == .main ? TypeLevel.header.font : TypeLevel.footer.font)
                .foregroundStyle(foreground)
                .padding(.horizontal, rank == .main ? 54 : 34)
                .padding(.vertical, rank == .main ? 20 : 16)
                .background(background, in: Capsule())
        }
        .bareFocusableButton()
        .focused(focus, equals: identifier)
        .focusHighlight(isFocused, scale: Tokens.Focus.buttonScale, accent: ColorRole.brandLight.color)
    }

    private var foreground: Color {
        switch rank {
        case .main: isFocused ? ColorRole.text.color : ColorRole.reason.color
        case .beside: isFocused ? ColorRole.reason.color : ColorRole.textMatt.color
        }
    }

    private var background: Color {
        switch rank {
        case .main: isFocused ? ColorRole.tag.color : ColorRole.text.color
        case .beside: isFocused ? ColorRole.text.color : .clear
        }
    }
}

/// A failure with its cause — **color and word**, as everywhere in this app.
struct SetupErrorLine: View {

    let text: Text

    var body: some View {
        Label {
            text
        } icon: {
            Image(systemName: Glyph.disruption.name)
        }
        .font(TypeLevel.footer.font)
        .foregroundStyle(ColorRole.live.color)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 1100, alignment: .leading)
    }
}

/// A quiet sentence under a step.
struct SetupNote: View {

    let text: Text

    var body: some View {
        text
            .font(TypeLevel.text.font)
            .foregroundStyle(ColorRole.textMatt.color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 1100, alignment: .leading)
    }
}

extension SetupProfile {

    /// "Lea · Jellyfin".
    func sheetTitle(_ source: String) -> String {
        "\(profile.name) · \(source)"
    }
}
