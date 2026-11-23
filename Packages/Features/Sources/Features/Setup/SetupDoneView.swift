import Core
import DesignSystem
import Flows
import ParentalControls
import ProfileKit
import SwiftUI

/// A7 — **"All set, Lea": one ending for every way**, also for "only IPTV" (AP88 §1.2, design A
/// of 2026-11-15).
///
/// The page lists what the profile brought along (✓ done, ◔ a CL-Server request that is still
/// waiting), the switch "Start automatically as Lea" (``ProfileKit/StartChoice``, applied by the
/// machine on "Let's go") and the two ways on: "Add another profile" back to A3 and "Let's go" to
/// the home screen. **The focus stands on "Let's go"**; ◀ reaches the further profile, ▲ the switch.
///
/// **A child without its own limit on this device gets one row more** (§10.1, also a child from
/// iCloud): it shows the profile sheet with the limit choice in place of the page — the place where
/// a profile's limit already lives — behind the door `profile`, so that a child cannot raise its
/// own limit here.
struct SetupDoneView: View {

    /// One line of the list — **a value, so that the checks read it without a screen.**
    nonisolated struct Line: Equatable, Sendable {
        let kind: Access.Kind
        let caption: SourcesView.Look.Caption
        let waiting: Bool
    }

    let summary: SetupSummary
    let profile: SetupProfile?
    /// The profile whose IPTV lists this one took over (``Flows/SetupMachine/listsCopied(for:)``).
    let copiedFrom: String?
    let send: (SetupInput) -> Void

    @FocusState private var focus: String?
    @State private var editsLimit = false
    @State private var limitSet = false

    nonisolated static let startID = "los"
    nonisolated static let anotherID = "weiteres-profil"
    nonisolated static let startChoiceID = "startwahl"
    nonisolated static let childLimitID = "grenze"

    /// The sources the profile came out with — **only what is done or waiting**; an open source
    /// is no news on the last page and waits in the settings.
    nonisolated static func lines(_ rows: [SourceRow], copiedFrom: String?) -> [Line] {
        rows.compactMap { row in
            switch row.state {
            case .done:
                let look = SourcesView.look(row.kind, row.state, copiedFrom: copiedFrom)
                return Line(kind: row.kind, caption: look.caption, waiting: false)
            case .waiting:
                return Line(kind: row.kind, caption: .waiting, waiting: true)
            default:
                return nil
            }
        }
    }

    var body: some View {
        if editsLimit, profile != nil {
            limitSheet
        } else {
            page
        }
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: 0) {
            SetupStepHead(stage: .done, title: AppLanguageSetting.text("setup.done.head \(summary.name)"))
            header
                .padding(.top, 48)
            VStack(alignment: .leading, spacing: 22) {
                ForEach(Self.lines(summary.rows, copiedFrom: copiedFrom), id: \.kind) { line in
                    lineView(line)
                }
            }
            .padding(.top, 40)
            .accessibilityElement(children: .combine)
            choices
                .padding(.top, 48)
                .frame(maxWidth: 1100, alignment: .leading)
                .focusSection()
            Spacer(minLength: 0)
            footer
        }
        .padding(.horizontal, MetricsBoard.tv.margin)
        .padding(.vertical, TVMetrics.topMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { focus = Self.startID }
        .onExitCommand { send(.back) }
    }

    private var header: some View {
        HStack(spacing: 24) {
            if let profile = profile?.profile {
                ProfileCircle(
                    letter: profile.initial,
                    avatar: profile.avatar,
                    edge: 72,
                    font: TypeLevel.header.font,
                    letterColor: ColorRole.reason.color,
                    surface: ProfileColor.tag(profile.color.rawValue),
                    frame: nil)
            }
            Text(app: "setup.done.title \(summary.name)")
                .font(TypeLevel.section.font)
                .foregroundStyle(ColorRole.text.color)
        }
    }

    private func lineView(_ line: Line) -> some View {
        HStack(spacing: 28) {
            Image(systemName: line.waiting ? Glyph.pending.name : Glyph.done.name)
                .font(TypeLevel.header.font)
                .foregroundStyle(line.waiting ? ColorRole.textMatt.color : ColorRole.brandLight.color)
                .frame(width: 56)
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: SourcesView.sourceName(line.kind))
                    .font(TypeLevel.header.font)
                    .foregroundStyle(ColorRole.text.color)
                Group {
                    if line.waiting {
                        Text(app: "setup.done.waiting")
                    } else {
                        SourcesView.captionText(line.caption)
                    }
                }
                .font(TypeLevel.lowercased.font)
                .foregroundStyle(ColorRole.textMatt.color)
                .lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private var choices: some View {
        VStack(alignment: .leading, spacing: 16) {
            SwitchRow(
                wording: AppLanguageSetting.text("setup.done.startAs \(summary.name)"),
                on: Binding(get: { summary.startChoice }, set: { send(.setStartChoice($0)) }),
                identifier: Self.startChoiceID, focus: $focus)
            if summary.offersChildLimit {
                SwitchRow(
                    wording: childLimitWording,
                    on: Binding(get: { limitSet }, set: { _ in editsLimit = true }),
                    identifier: Self.childLimitID, focus: $focus)
            }
        }
    }

    private var childLimitWording: String {
        limitSet
            ? AppLanguageSetting.text("setup.done.childLimitSet \(summary.name)")
            : AppLanguageSetting.text("setup.done.childLimit \(summary.name)")
    }

    private var footer: some View {
        HStack(spacing: 30) {
            Spacer(minLength: 0)
            SetupButton(title: "setup.done.anotherProfile", identifier: Self.anotherID, focus: $focus) {
                send(.addAnotherProfile)
            }
            SetupButton(title: "setup.done.start", rank: .main, identifier: Self.startID, focus: $focus) {
                send(.start)
            }
        }
        .focusSection()
    }

    // MARK: - The child's limit

    @ViewBuilder
    private var limitSheet: some View {
        if let child = profile?.profile {
            ParentalControlsDoor("profile") {
                ProfileSheet(
                    existing: child,
                    suggestion: child.color,
                    previousLimit: ProfileManagement().limit(forItem: child.identifier),
                    onSave: { name, color, kind, limit, avatar in
                        let draft = ProfileDraft(
                            name: name, color: color, kind: kind, limit: limit, avatar: avatar)
                        ProfileManagement().save(draft, existing: child)
                        limitSet = limit != nil
                        editsLimit = false
                    },
                    onCancel: { editsLimit = false })
            }
        }
    }
}
