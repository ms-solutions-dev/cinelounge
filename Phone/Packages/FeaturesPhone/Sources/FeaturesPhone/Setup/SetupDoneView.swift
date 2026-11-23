import Core
import DesignSystemPhone
import Flows
import ProfileKit
import SwiftUI

/// A7 — **what is set up now, for every path** (AP88 §2, break point 6).
///
/// **Built for the phone on its own** (wave 6): the TV's A7 comes with its wave 5, and the phone
/// does not wait for it. The content is the machine's (``Flows/SetupSummary``): a row per source
/// that is ✓ or waiting, "Start automatically as Lea", "Create another profile" back to A3, and
/// "Let's go". The rows are the answer to "did I do that right" — a "Done" without them leaves open
/// whether the access arrived.
///
/// **Parental controls stand as a sentence** — the phone has no settings behind the setup yet, and
/// a button that leads nowhere would be worse than the hint where they are.
struct SetupDoneView: View {

    let summary: SetupSummary
    let send: (SetupInput) -> Void

    /// The rows A7 lists — **only what is set up or waiting**; an untouched source is no result.
    nonisolated static func listed(_ rows: [SourceRow]) -> [SourceRow] {
        rows.filter { row in
            switch row.state {
            case .done, .waiting: true
            default: false
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MetricsBoard.phone.gutter) {
                Text(app: "setup.done.title")
                    .font(TypeLevel.title.font)
                    .foregroundStyle(ColorRole.text.color)
                    .padding(.top, MetricsBoard.phone.section)

                Text(verbatim: summary.name)
                    .font(TypeLevel.header.font)
                    .foregroundStyle(ColorRole.textMatt.color)

                ForEach(Self.listed(summary.rows), id: \.kind) { row in
                    rowView(row)
                }

                Toggle(
                    isOn: Binding(get: { summary.startChoice }, set: { send(.setStartChoice($0)) })
                ) {
                    Text(app: "profiles.startAs")
                        .font(TypeLevel.footer.font)
                        .foregroundStyle(ColorRole.text.color)
                }
                .tint(ColorRole.brandLight.color)
                .padding(.top, MetricsBoard.phone.gutter)

                Footnote(message: "setup.done.parental")

                Button {
                    send(.start)
                } label: {
                    Text(app: "setup.done.go").frame(maxWidth: .infinity)
                }
                .buttonStyle(.loud)
                .padding(.top, MetricsBoard.phone.gutter)

                Button {
                    send(.addAnotherProfile)
                } label: {
                    Text(app: "setup.done.another").frame(maxWidth: .infinity)
                }
                .buttonStyle(.quiet)
            }
            .padding(.horizontal, MetricsBoard.phone.margin)
            .padding(.bottom, MetricsBoard.phone.section)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func rowView(_ row: SourceRow) -> some View {
        HStack(spacing: 8) {
            Image(systemName: row.state == .waiting ? Glyph.pending.name : Glyph.done.pair.filled)
                .foregroundStyle(row.state == .waiting ? ColorRole.textMatt.color : ColorRole.success.color)
                .accessibilityHidden(true)
            Text(verbatim: SetupSourcesView.sourceName(row.kind))
                .font(TypeLevel.footer.font)
                .foregroundStyle(ColorRole.text.color)
            Spacer(minLength: 8)
            detail(row.state)
                .font(TypeLevel.label.font)
                .foregroundStyle(ColorRole.textMatt.color)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func detail(_ state: SourceRowState) -> some View {
        switch state {
        case .waiting: Text(app: "setup.clServer.waiting")
        case .done(let detail): Text(verbatim: detail)
        default: EmptyView()
        }
    }
}
