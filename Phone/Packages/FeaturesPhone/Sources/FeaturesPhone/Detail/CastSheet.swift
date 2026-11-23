import DesignSystemPhone
import SwiftUI

/// All names — ordered by role.
///
/// **A list and not a second row of circles.** The row above answers "who is in it";
/// here one answers "is X in it", and for that one reads top to bottom. Forty circles
/// in a grid would be the same row in a more cumbersome form.
///
/// **Director and writer are included, but under their own heading.** In the row above
/// they are missing on purpose; here they would be missing without reason — the sheet is
/// the place that promises completeness.
struct CastSheet: View {

    let cast: [PersonDetail]
    /// `nil` means: no career access, the rows are not buttons.
    var openPerson: ((PersonDetail) -> Void)?

    var body: some View {
        SheetFrame(title: "detail.cast") {
            ForEach(PersonDetail.Role.allCases, id: \.self) { task in
                let group = cast.filter { $0.task == task }
                if !group.isEmpty {
                    SectionHeader(title: task.titleKey)
                    ForEach(group) { person in
                        PersonRow(
                            person: person,
                            open: openPerson.map { action in { action(person) } })
                    }
                }
            }
            if openPerson == nil {
                Footnote(message: "detail.noFilmographyKey")
            }
        }
    }
}

/// A small face, next to it name, role and voice.
struct PersonRow: View {

    let person: PersonDetail
    var open: (() -> Void)?

    private var row: some View {
        HStack(spacing: MetricsBoard.phone.gutter) {
            RemoteImage(source: person.imageAddress, longestEdge: 40, placeholder: Glyph.person.name)
                .frame(width: 40, height: 40)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: person.name)
                    .font(TypeLevel.text.font)
                    .foregroundStyle(ColorRole.text.color)
                    .lineLimit(1)
                if let characterName = person.characterName {
                    Text(verbatim: characterName)
                        .font(TypeLevel.label.font)
                        .foregroundStyle(ColorRole.textQuiet.color)
                        .lineLimit(1)
                }
                if let voiceActor = person.voiceActor {
                    Text(app: "cast.germanVoice \(voiceActor)")
                        .font(TypeLevel.label.font)
                        .foregroundStyle(ColorRole.brandLight.color)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: MetricsBoard.phone.gutter)

            if open != nil {
                Image(systemName: Glyph.next.name)
                    .iconSize(13, weight: .semibold)
                    .foregroundStyle(ColorRole.textQuiet.color)
            }
        }
        .padding(.horizontal, MetricsBoard.phone.margin)
        .frame(minHeight: Metrics.choiceRow)
        .contentShape(Rectangle())
    }

    var body: some View {
        if let open {
            Button(action: open) { row }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
        } else {
            row.accessibilityElement(children: .combine)
        }
    }
}
