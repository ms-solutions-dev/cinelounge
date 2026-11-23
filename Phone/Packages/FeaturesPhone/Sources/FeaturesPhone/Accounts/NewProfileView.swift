import DesignSystemPhone
import Flows
import ParentalControls
import ProfileKit
import SwiftUI

/// Create or change a profile — **name, color and, when creating, the kind** (G3, finding B1).
///
/// **Until G3 this did not exist on the phone.** A profile arose here only at the end of
/// setup or came from the TV via iCloud, and parental controls said
/// "Child profiles are created on the TV". Profiles are self-contained (decision 3):
/// whoever stands before "Who is watching?" and does not find themselves creates themselves here — without an Apple account,
/// without a media server.
///
/// **The same draft as on the TV** (``Flows/ProfileDraft``) and the same way into
/// the book (``Flows/ProfileManagement/save(_:existing:)``): the color comes
/// suggested, the kind is there only when creating, a child gets its own limit.
/// **The profile picture is chosen afterwards in the person sheet** — the same image picker as before.
struct NewProfileView: View {

    /// The profile being edited — `nil` means create.
    let existing: Profile?
    /// Whether a PIN is set on the device — without it a child's limit does not apply.
    let isPinSet: Bool
    /// Whether the title is in the content — **yes in the sheet**; as a pushed view the bar
    /// carries it (``ViewID/titleKey``).
    let titleInContent: Bool
    /// Saves the draft; the view then closes the call site.
    let save: (ProfileDraft) -> Void

    @State private var draft: ProfileDraft

    init(
        existing: Profile?, suggestion: Profile.ColorTag, previousLimit: AgeLimit?,
        isPinSet: Bool, titleInContent: Bool = false,
        save: @escaping (ProfileDraft) -> Void
    ) {
        self.existing = existing
        self.isPinSet = isPinSet
        self.titleInContent = titleInContent
        self.save = save
        _draft = State(
            initialValue: ProfileDraft(
                existing: existing, suggestion: suggestion, previousLimit: previousLimit))
    }

    /// The levels of the limit — **first "as on the device"**, then ascending.
    static let slots: [AgeLimit?] = [nil] + AgeLimit.allCases.map { $0 }

    var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()

            ScrollSurface {
                VStack(alignment: .leading, spacing: 0) {
                    if titleInContent {
                        LargeTitle(title: existing == nil ? "profiles.newTitle" : "profiles.editTitle")
                    }
                    lookahead

                    SectionHeader(title: "profiles.name")
                    InputField(text: $draft.name, placeholder: "profiles.namePrompt", kind: .name)
                        .padding(.horizontal, MetricsBoard.phone.margin)

                    SectionHeader(title: "common.color")
                    colorChoice

                    // **The kind only when creating** — what could later be set to "Child"
                    // could also be set back (``Flows/ProfileManagement/update(_:name:color:avatar:)``).
                    if existing == nil {
                        SectionHeader(title: "profiles.kind")
                        ChoiceRow(
                            name: SettingsModel.text("profiles.adult"),
                            icon: Glyph.person.name, chosen: draft.kind == .adult
                        ) { draft.kind = .adult }
                        ChoiceRow(
                            name: SettingsModel.text("profiles.child"),
                            icon: Glyph.kind.name, chosen: draft.kind == .kind
                        ) { draft.kind = .kind }
                    }

                    if (existing?.kind ?? draft.kind) == .kind { limitsChoice }

                    Button {
                        guard draft.isValid else { return }
                        save(draft)
                    } label: {
                        Text(app: existing == nil ? "profiles.add" : "common.save")
                    }
                    .buttonStyle(.loud)
                    .disabled(!draft.isValid)
                    .padding(.horizontal, MetricsBoard.phone.margin)
                    .padding(.top, MetricsBoard.phone.section)
                }
                .padding(.top, MetricsBoard.phone.gutter)
            }
        }
    }

    /// What will stand in "Who is watching?" — a circle in the chosen color, the name below.
    private var lookahead: some View {
        VStack(spacing: 6) {
            ProfileCircle(
                letter: draft.initial.isEmpty ? "?" : draft.initial,
                avatar: draft.avatar, edge: MetricsBoard.phone.person,
                font: TypeLevel.section.font, letterColor: ColorRole.reason.color,
                surface: ProfileColor.tag(draft.color.rawValue) ?? ColorRole.surfaceHigh.color)
            if !draft.name.isEmpty {
                Text(verbatim: draft.name)
                    .font(TypeLevel.footer.font)
                    .foregroundStyle(ColorRole.text.color)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, MetricsBoard.phone.gutter)
        .accessibilityHidden(true)
    }

    /// The six profile colors as circles — **the chosen one with a checkmark** (shape, not only color).
    private var colorChoice: some View {
        HStack(spacing: MetricsBoard.phone.gutter) {
            ForEach(Profile.ColorTag.allCases, id: \.self) { tag in
                let chosen = draft.color == tag
                Button {
                    draft.color = tag
                } label: {
                    Circle()
                        .fill(ProfileColor.tag(tag.rawValue) ?? ColorRole.surfaceHigh.color)
                        .frame(width: Metrics.target, height: Metrics.target)
                        .overlay {
                            if chosen {
                                Image(systemName: Glyph.done.pair.outlined)
                                    .font(TypeLevel.header.font)
                                    .foregroundStyle(ColorRole.reason.color)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(appKey: "profiles.color." + tag.rawValue))
                .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(.horizontal, MetricsBoard.phone.margin)
    }

    /// A child's own limit — **the empty field means "as on the device"**, not
    /// "no limit": the stricter of profile and device always applies.
    @ViewBuilder
    private var limitsChoice: some View {
        SectionHeader(title: "childLock.limit")
        ChipRow(
            labels: Self.slots.map {
                $0.map(\.caption) ?? SettingsModel.text("profiles.childLimitDevice")
            },
            chosen: .init(
                get: { Self.slots.firstIndex(of: draft.limit) ?? 0 },
                set: { draft.limit = Self.slots[$0] }))
        if ProfileDraft.promptsForPin(kind: existing?.kind ?? draft.kind, isPinSet: isPinSet) {
            Footnote(message: "profiles.childNoPin")
        }
    }
}
