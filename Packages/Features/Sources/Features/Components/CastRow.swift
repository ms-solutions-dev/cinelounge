import Core
import DesignSystem
import RatingsKit
import SwiftUI

/// The cast as a row of round images.
///
/// Round and not rectangular, to set it apart from posters and episodes —
/// recognizable at a glance that people stand here and
/// not titles. Under the name stands the role: for anime "Spautrol Riaskupit"
/// is the more interesting piece of information than the voice actress's name.
public struct CastRow: View {

    let cast: [Person]
    let imageURL: (Person) -> URL?
    /// What happens on a press. `nil` means: the row is there to be looked at.
    ///
    /// As an option and not a requirement, because the row appears in two places
    /// and only in one of them is there anything to open — whoever uses it without a target
    /// should not get a button that does nothing.
    let onSelect: ((Person) -> Void)?
    /// The German voice for a role — or `nil` where there is none.
    ///
    /// **Optional and not required**, since it exists only for anime (see
    /// ``GermanVoices``). Where nothing comes back, the row stays single-line; an
    /// empty second line under every face would look like an error.
    let voice: ((Person) -> VoiceCredit?)?
    @FocusState.Binding var focus: String?

    @Environment(\.accentPalette) private var palette

    public init(
        cast: [Person],
        imageURL: @escaping (Person) -> URL?,
        onSelect: ((Person) -> Void)? = nil,
        voice: ((Person) -> VoiceCredit?)? = nil,
        focus: FocusState<String?>.Binding
    ) {
        self.cast = cast
        self.imageURL = imageURL
        self.onSelect = onSelect
        self.voice = voice
        self._focus = focus
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(app: "detail.cast")
                // **The capitals live here and not in the translation** (AP25,
                // 2026-09-11). "BESETZUNG" in the language file had three consequences: the
                // screen reader spells it out depending on the voice, a shared key
                // with the phone was impossible, and the design decision "capitals
                // here" lay in a language file instead of in a view.
                .textCase(.uppercase)
                .font(TypeLevel.footer.font)
                .kerning(3)
                .foregroundStyle(ColorRole.textQuiet.color)

            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 34) {
                    ForEach(cast) { person in
                        let id = "cast-" + person.id

                        VStack(spacing: 14) {
                            RemoteImage(
                                url: imageURL(person),
                                displaySize: CGSize(
                                    width: MetricsBoard.tv.person,
                                    height: MetricsBoard.tv.person
                                ),
                                // A person, not a film strip: the provider
                                // delivers only **names** for its titles, no
                                // portraits — the circle stays empty there,
                                // and what is in it should at least hint at the
                                // right thing (user finding 2026-08-22).
                                placeholderSymbol: "person.fill"
                            )
                            .frame(
                                width: MetricsBoard.tv.person,
                                height: MetricsBoard.tv.person
                            )
                            .clipShape(Circle())
                            .focusHighlight(
                                focus == id,
                                accent: Color(palette, .bright)
                            )

                            VStack(spacing: 4) {
                                Text(verbatim: person.name)
                                    .font(TypeLevel.footer.font)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(ColorRole.text.color)
                                if let character = person.character, !character.isEmpty {
                                    Text(verbatim: character)
                                        .font(TypeLevel.lowercased.font)
                                        .foregroundStyle(ColorRole.textMatt.color)
                                }
                                // **The German voice, where there is one.**
                                //
                                // With a prefix and not merely as a third name:
                                // otherwise two people would stand one below the other without
                                // distinction, and whoever sees the row for the first time
                                // would take the second for a second role.
                                if let voice, let credit = voice(person) {
                                    Text(app: "detail.germanVoice \(credit.name)")
                                        .font(TypeLevel.lowercased.font)
                                        .foregroundStyle(Color(palette, .bright))
                                        .padding(.top, 2)
                                }
                            }
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .frame(width: MetricsBoard.tv.person + 30)
                        }
                        // **Button or merely focusable, depending on the target.** A
                        // button that triggers nothing is worse on a remote than none at all: the
                        // focus sits on it, one presses, and nothing responds.
                        .modifier(
                            PersonTap(action: onSelect.map { action in { action(person) } })
                        )
                        .focused($focus, equals: id)
                    }
                }
                .padding(.vertical, 20)
            }
            .scrollClipDisabled()
            .focusSection()
        }
    }
}

/// Turns a tile into a button — but only if there is something to trigger.
///
/// Visible in the module and not private, because the player's info column
/// draws its cast itself (with a different path to the image) and needs the same
/// distinction.
///
/// The reasoning is at ``ExitCommand``, it is the same trap in green: a
/// handler that does nothing is not a null case but a dead end.
struct PersonTap: ViewModifier {

    let action: (() -> Void)?

    func body(content: Content) -> some View {
        if let action {
            Button(action: action) { content }
                .bareFocusableButton()
        } else {
            content.focusable()
        }
    }
}
