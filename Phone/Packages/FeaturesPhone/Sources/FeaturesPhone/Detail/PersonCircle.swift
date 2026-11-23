import DesignSystemPhone
import SwiftUI

/// A face, 64 points, round — with name, role and the German voice.
///
/// **Round and not rectangular**, so that the row differs from posters and episodes:
/// at a glance it is clear that people stand here and not
/// titles.
///
/// **Without filmography access the circle stops being a button.** A button that triggers
/// nothing is worse than none at all — you press, nothing answers, and the
/// third time you no longer press. So it is not the view that decides whether it looks
/// tappable, but the caller, by passing an action or not.
///
/// **The German voice stands with a prefix, not as a third name.** Stacked, two
/// people would otherwise stand there without distinction, and anyone seeing the row for the first time
/// would take the second for a second role.
struct PersonCircle: View {

    let person: PersonDetail
    /// `nil` means: view only.
    var open: (() -> Void)?

    /// The width of a column — a little more than the image, so that two-line names do not
    /// bump into the neighboring face.
    static let width: CGFloat = MetricsBoard.phone.person + 22

    var body: some View {
        if let open {
            Button(action: open) { column.contentShape(Rectangle()) }
                .buttonStyle(.plain)
        } else {
            column
        }
    }

    private var column: some View {
        VStack(spacing: 6) {
            RemoteImage(
                source: person.imageAddress,
                longestEdge: MetricsBoard.phone.person,
                placeholder: Glyph.person.name
            )
            .frame(width: MetricsBoard.phone.person, height: MetricsBoard.phone.person)
            .clipShape(Circle())
            .overlay { Circle().strokeBorder(ColorRole.outline.color, lineWidth: 0.5) }

            VStack(spacing: 2) {
                Text(verbatim: person.name)
                    .font(TypeLevel.lowercased.font)
                    .foregroundStyle(ColorRole.text.color)
                if let characterName = person.characterName {
                    Text(verbatim: characterName)
                        .font(TypeLevel.lowercased.font.weight(.regular))
                        .foregroundStyle(ColorRole.textQuiet.color)
                }
                if let voiceActor = person.voiceActor {
                    Text(app: "cast.germanVoice \(voiceActor)")
                        .font(TypeLevel.lowercased.font.weight(.regular))
                        .foregroundStyle(ColorRole.brandLight.color)
                }
            }
            .multilineTextAlignment(.center)
            .lineLimit(2)
        }
        // **Top-aligned, like the posters.** The same finding of 2026-09-05, one row
        // further on: a two-line name makes a column taller, and without this line
        // the faces next to it slide down by half a text line.
        .frame(width: Self.width, alignment: .top)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}
