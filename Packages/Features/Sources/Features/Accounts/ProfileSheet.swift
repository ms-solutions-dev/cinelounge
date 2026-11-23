import Core
import DesignSystem
import Flows
import ParentalControls
import ProfileKit
import SwiftUI

/// Creating or renaming a profile: **name, color — and when creating, the kind.**
///
/// **The TV can now do this itself** (AP41, row 5). Until here a
/// person came into being only by someone signing in to a Jellyfin: Whoever
/// wanted to set up the TV for a child who does not yet own anything had no
/// way. The rule *"Typing is the most expensive operation"* remains — it is a reason
/// to ask for little, and not a prohibition. **One** word is asked for.
///
/// **The kind is only there when creating.** What could be switched to "child" afterwards
/// could also be switched back — the sentence of the former child-account question (removed in
/// AP88 wave 5): Whoever knows the PIN would then not have to bypass the parental controls, they
/// would switch them off.
///
/// **The color comes suggested and not empty.** ``ProfileModel/nextColor`` takes
/// the first that nobody has yet; whoever keeps it has one decision fewer, and whoever
/// changes it sees immediately what they get.
///
/// **Since AP49 also the profile picture** — a 4 × 4 grid of the bundled motifs and
/// "No picture", following the pattern of the color choice. The preview next to it shows what will
/// stand in "Who is watching?": the whole motif as title image, the circle above it.
struct ProfileSheet: View {

    /// What currently stands in the sheet — **and what of it goes out on saving.**
    ///
    /// **One value and not five `@State`**, so that the path from the sheet to `onSave` is a
    /// computation and not a line in the button body: `ProfilBlattTests` checks that the
    /// picture choice arrives. Exactly this connection is the one you do not see on screen
    /// — the preview showed the picture, but it would not be saved anyway.
    ///
    /// Since G3 the draft is shared (``Flows/ProfileDraft``) — the phone now creates
    /// profiles with the same value.
    typealias Draft = ProfileDraft

    /// The motifs in rows of `columns` each — **flat and not as a grid.**
    ///
    /// For the same reason as in ``Regalquellen``: Focus on tvOS moves reliably
    /// only between built siblings, and a `LazyVGrid` does not build everything.
    nonisolated static func rows(_ motive: [AvatarMotif], columns: Int) -> [[AvatarMotif]] {
        guard columns > 0 else { return [] }
        return stride(from: 0, to: motive.count, by: columns).map {
            Array(motive[$0..<min($0 + columns, motive.count)])
        }
    }

    /// The profile being changed — `nil` means: a new one.
    let existing: Profile?
    /// The suggested color for a new profile.
    let suggestion: Profile.ColorTag
    /// The profile's own limit on opening — `nil` means "as on the device".
    let previousLimit: AgeLimit?
    /// Accepts the result. For an existing profile the kind is the old one.
    ///
    /// **The limit always goes along, even for adults** — there as `nil`, and the
    /// caller writes it only for children. This way one place decides whether it applies,
    /// and not two.
    ///
    /// **The profile picture comes as the fifth and always** (AP49) — `""` means "No picture" and
    /// is a choice, `nil` means "never decided" and stays so as long as nobody touches the
    /// picture choice. See ``ProfileKit/Profil/avatar``.
    let onSave: (String, Profile.ColorTag, Profile.Kind, AgeLimit?, String?) -> Void
    let onCancel: () -> Void
    /// Whether a PIN lies on the device — without it the limit has no effect, see ``promptsForPin(kind:isPinSet:)``.
    let isPinSet: Bool
    /// **A3 of the first setup** (AP88): the head with the three marks ("Profile · Sources ·
    /// Done") above the title, "Continue" instead of "Save" and "Back" instead of "Cancel" —
    /// the same sheet as in "Who is watching?", so that a profile comes into being in one form.
    /// `nil` outside the setup.
    let setupHead: String?

    /// Whether the sheet below the limit choice says that it **has no effect without a PIN**
    /// (cross-check AP45, 2026-09-25, M2).
    ///
    /// ``ParentalControls/ProtectionRule/applies`` requires a PIN; without one the
    /// shell builds the child interface for a child but filters nothing. Whoever chose a
    /// limit here saw no difference from one that works — and believed their child
    /// to be protected. The same sentence as the household-PIN step of the setup refers to, so
    /// that it remains one piece of information and not two.
    static func promptsForPin(kind: Profile.Kind, isPinSet: Bool) -> Bool {
        ProfileDraft.promptsForPin(kind: kind, isPinSet: isPinSet)
    }

    /// "Continue" in the setup — **the next step follows**, nothing is merely stored away.
    nonisolated static func saveTitle(inSetup: Bool) -> String {
        inSetup ? "setup.continue" : "common.save"
    }

    /// "Back" in the setup — **it leads to A2 or A7 and cancels nothing that was stored.**
    nonisolated static func cancelTitle(inSetup: Bool) -> String {
        inSetup ? "common.back" : "common.cancel"
    }

    @State private var draft: Draft
    @FocusState private var focus: String?

    init(
        existing: Profile?,
        suggestion: Profile.ColorTag,
        previousLimit: AgeLimit?,
        onSave: @escaping (String, Profile.ColorTag, Profile.Kind, AgeLimit?, String?) -> Void,
        onCancel: @escaping () -> Void,
        isPinSet: Bool = true,
        setupHead: String? = nil
    ) {
        self.isPinSet = isPinSet
        self.setupHead = setupHead
        self.existing = existing
        self.suggestion = suggestion
        self.previousLimit = previousLimit
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(
            initialValue: Draft(
                name: existing?.name ?? "",
                color: existing?.color ?? suggestion,
                kind: existing?.kind ?? .adult,
                limit: previousLimit,
                avatar: existing?.avatar))
    }

    private var isNew: Bool { existing == nil }

    var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()

            // **Two columns, because the grid has a height of its own:** Placed below the
            // existing rows, the sheet would run beyond the screen height, and on
            // tvOS it then scrolls as soon as focus enters the grid — the buttons
            // would vanish from the picture while one chooses.
            HStack(alignment: .top, spacing: 60) {
                VStack(alignment: .leading, spacing: 34) {
                    if let setupHead { SetupStepHead(stage: .profile, title: setupHead) }
                    Text(appKey: isNew ? "profiles.newTitle" : "profiles.editTitle")
                        .font(TypeLevel.section.font)
                        .foregroundStyle(ColorRole.text.color)

                    nameField
                    colorChoice
                    if isNew { kindChoice }
                    if draft.kind == .kind { limitsChoice }
                    buttons
                }
                .frame(maxWidth: 1000, alignment: .leading)

                VStack(alignment: .leading, spacing: 30) {
                    lookahead
                    imageChoice
                }
            }
            .padding(50)
            .frame(maxWidth: 1760, alignment: .leading)
        }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(app: "profiles.name")
                .font(TypeLevel.lowercased.font)
                .foregroundStyle(ColorRole.textQuiet.color)

            TextField(text: $draft.name) { Text(app: "profiles.namePrompt") }
                // **Running text and no identifier:** A name that someone
                // assigns themselves may begin with a capital letter.
                .keyboard(forItem: .prose)
                .remoteKeyboard($draft.name, pending: focus == "name")
                .textFieldStyle(.plain)
                .font(TypeLevel.text.font)
                .frame(maxWidth: 620)
                .focused($focus, equals: "name")
        }
    }

    /// Title image and circle as they will stand in "Who is watching?" — **while one chooses
    /// and types.**
    ///
    /// Color, picture and initial together are what one later recognizes the profile
    /// by; showing them only after saving would mean letting the choice be made
    /// blind. Until AP49 only the 68-pt circle stood here next to the name field; with a
    /// picture it would no longer carry what "Who is watching?" shows.
    private var lookahead: some View {
        ZStack {
            ProfileTitleImage(avatar: draft.avatar, color: draft.color, opacity: 0.45)
            VStack(spacing: 12) {
                ProfileCircle(
                    letter: draft.initial,
                    avatar: draft.avatar,
                    edge: 120,
                    font: TypeLevel.title.font,
                    letterColor: ColorRole.reason.color,
                    surface: ProfileColor.tag(draft.color.rawValue),
                    frame: nil)
                Text(verbatim: draft.name)
                    .font(TypeLevel.footer.font)
                    .foregroundStyle(ColorRole.text.color)
                    .lineLimit(1)
            }
        }
        .frame(width: 520, height: 292)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    /// **Sixteen motifs in four rows and "No picture" above them** — the pattern of the
    /// color choice: focusable circles, the chosen one carries a checkmark, focus enlarges.
    ///
    /// **"No picture" stands on top as a pill and not as a seventeenth tile.** A tile
    /// without a picture would look like a motif that has not loaded — exactly the empty circle that
    /// the fallback prevents everywhere else.
    private var imageChoice: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 18) {
                Text(app: "profiles.avatar")
                    .font(TypeLevel.lowercased.font)
                    .foregroundStyle(ColorRole.textQuiet.color)
                ChoiceRow(
                    title: "profiles.avatarNone",
                    chosen: (draft.avatar ?? "").isEmpty,
                    identifier: "bild-keins",
                    focus: $focus
                        // **`""` and not `nil`** — "No picture" is a choice with a timestamp,
                        // otherwise every other device with a picture would win (cross-check 2026-09-25).
                ) { draft.avatar = "" }
            }

            VStack(alignment: .leading, spacing: 16) {
                ForEach(
                    Array(Self.rows(AvatarMotif.all, columns: 4).enumerated()), id: \.offset
                ) { _, row in
                    HStack(spacing: 16) {
                        ForEach(row) { motif in imageTile(motif) }
                    }
                }
            }
        }
    }

    private func imageTile(_ motif: AvatarMotif) -> some View {
        let identifier = "bild-" + motif.name
        let chosen = draft.avatar == motif.name
        return Button {
            draft.avatar = motif.name
        } label: {
            ProfileCircle(
                letter: "",
                avatar: motif.name,
                edge: 86,
                font: TypeLevel.footer.font,
                letterColor: ColorRole.reason.color,
                surface: ColorRole.surface.color,
                frame: focus == identifier ? ColorRole.text.color : nil
            )
            .overlay {
                // **A checkmark and not just a ring** — the same sentence as in the
                // color choice: From three meters a ring is an edge, a symbol is a
                // statement. On a picture it needs a reason of its own.
                if chosen {
                    Image(systemName: "checkmark")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(ColorRole.reason.color)
                        .frame(width: 44, height: 44)
                        .background(ColorRole.text.color, in: Circle())
                }
            }
            .scaleEffect(focus == identifier ? 1.14 : 1)
            .animation(.easeOut(duration: 0.15), value: focus == identifier)
        }
        .bareFocusableButton()
        .focused($focus, equals: identifier)
        .info(Text(appKey: motif.info), .chosen(chosen))
    }

    private var colorChoice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(app: "common.color")
                .font(TypeLevel.lowercased.font)
                .foregroundStyle(ColorRole.textQuiet.color)

            HStack(spacing: 18) {
                ForEach(Profile.ColorTag.allCases, id: \.rawValue) { tag in
                    Button {
                        draft.color = tag
                    } label: {
                        Circle()
                            .fill(ProfileColor.tag(tag.rawValue))
                            .frame(width: 58, height: 58)
                            .overlay {
                                // **The choice carries a checkmark and not just a
                                // ring.** From three meters a ring around a colored circle is an
                                // edge; a symbol is a statement.
                                if draft.color == tag {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 24, weight: .bold))
                                        .foregroundStyle(ColorRole.reason.color)
                                }
                            }
                            .scaleEffect(focus == tag.rawValue ? 1.18 : 1)
                    }
                    .bareFocusableButton()
                    .focused($focus, equals: tag.rawValue)
                    .info(Text(appKey: "profiles.color." + tag.rawValue))
                }
            }
        }
    }

    private var kindChoice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(app: "profiles.kind")
                .font(TypeLevel.lowercased.font)
                .foregroundStyle(ColorRole.textQuiet.color)

            HStack(spacing: 18) {
                kindButton(.adult, key: "profiles.adult", symbol: "person.crop.circle")
                kindButton(.kind, key: "profiles.child", symbol: "figure.child")
            }
        }
    }

    private func kindButton(_ choice: Profile.Kind, key: String, symbol: String) -> some View {
        Button {
            draft.kind = choice
        } label: {
            Label {
                Text(appKey: key)
            } icon: {
                Image(systemName: draft.kind == choice ? "checkmark" : symbol)
            }
            .font(TypeLevel.footer.font)
            .settingsFont(isFocused: focus == choice.rawValue)
            .settingsSurface(.pill, isFocused: focus == choice.rawValue)
        }
        .bareFocusableButton()
        .focused($focus, equals: choice.rawValue)
    }

    /// The age limit of **this** child (AP45, Decision 7 of 2026-09-24).
    ///
    /// **The empty field means "as on the device" and not "no limit".** The stricter
    /// of profile and device always applies (``ParentalControls/AgeLimit/forItem(profile:device:)``);
    /// without a limit of its own the floor applies that ``ParentalControlsView`` sets on the device.
    /// "No limit" promised something that cannot be set here at all.
    ///
    /// **From the building block and not by hand**, so that the row counter does not rise.
    private var limitsChoice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(app: "childLock.limit")
                .font(TypeLevel.lowercased.font)
                .foregroundStyle(ColorRole.textQuiet.color)

            HStack(spacing: 14) {
                ChoiceRow(
                    title: "profiles.childLimitDevice",
                    chosen: draft.limit == nil,
                    identifier: "grenze-keine",
                    focus: $focus
                ) { draft.limit = nil }
                ForEach(AgeLimit.allCases, id: \.rawValue) { tier in
                    ChoiceRow(
                        wording: tier.caption,
                        chosen: draft.limit == tier,
                        identifier: "grenze-" + String(tier.rawValue),
                        focus: $focus
                    ) { draft.limit = tier }
                }
            }

            if Self.promptsForPin(kind: draft.kind, isPinSet: isPinSet) {
                Text(app: "accounts.newNoPinYet")
                    .font(TypeLevel.lowercased.font)
                    .foregroundStyle(ColorRole.live.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: 18) {
            Button {
                // **An empty name does not save** — a profile without a name would be a
                // circle without a letter in a list without names, and nobody would know
                // whose it is.
                //
                // **It is discarded in the body and not with `.disabled`.** On tvOS a
                // disabled button is not a pale button but none: It drops out of
                // the focus tree, and focus lands somewhere afterwards. Here that would be
                // particularly unpleasant — the button would vanish at the moment
                // someone empties the name field, and focus would jump out of the row.
                draft.save(onSave)
            } label: {
                Text(appKey: Self.saveTitle(inSetup: setupHead != nil))
                    .font(TypeLevel.footer.font)
                    .settingsFont(isFocused: focus == "sichern")
                    .settingsSurface(.pill, isFocused: focus == "sichern")
                    .opacity(draft.initial.isEmpty ? 0.45 : 1)
            }
            .bareFocusableButton()
            .focused($focus, equals: "sichern")

            Button(action: onCancel) {
                Text(appKey: Self.cancelTitle(inSetup: setupHead != nil))
                    .font(TypeLevel.footer.font)
                    .settingsFont(isFocused: focus == "abbrechen")
                    .settingsSurface(.pill, isFocused: focus == "abbrechen")
            }
            .bareFocusableButton()
            .focused($focus, equals: "abbrechen")
        }
    }
}
