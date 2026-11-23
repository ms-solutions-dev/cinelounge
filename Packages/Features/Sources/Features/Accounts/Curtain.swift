import DesignSystem
import SwiftUI

/// What stands in place of a locked area — **a curtain, not a rejection.**
///
/// **The difference from the door.** The door (``ParentalControlsState/isAllowed(finished:)``) sits at
/// an action and asks a question. The curtain hangs on **focus**: it covers
/// what would be shown anyway, because the area in Settings follows navigation
/// and not the press. It asks nothing on its own — otherwise every move
/// through the list would bring up the PIN sheet.
///
/// **It carries a focus target, and that is mandatory, not decoration.** A content area
/// without a single target is a wall on tvOS: the right press from the area list
/// fizzles out, and whoever wants to enter a PIN cannot even get there. This exact
/// sickness ``DiagnosticsSettings`` has had once before with the log list.
///
/// **The reason is shown with it.** "Not allowed" explains nothing; ``LockedDoors`` keeps
/// a sentence of its own per door, and this is the place where it is needed.
struct Curtain: View {

    /// The door that is closed here — the raw value from ``LockedDoors``.
    let door: String

    /// What lies behind it and why it is closed. `nil` omits the row.
    let reason: String?

    /// Asks for the PIN. The holder then shows its sheet.
    let asks: () -> Void

    /// The ID of the focus target — the area reports it as its first target.
    static let buttonID = "vorhang-pin"

    @FocusState private var focus: String?
    @Environment(\.settingsEntryRequest) private var entryRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: "lock.fill")
                .font(.system(size: 46))
                .foregroundStyle(ColorRole.textMatt.color)
                .padding(.bottom, 26)

            Text(app: "childLock.curtain.title")
                .font(TypeLevel.title.font)
                .foregroundStyle(ColorRole.text.color)

            if let reason {
                Text(verbatim: reason)
                    .font(TypeLevel.text.font)
                    .foregroundStyle(ColorRole.textMatt.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 900, alignment: .leading)
                    .padding(.top, 12)
            }

            Button(action: asks) {
                Text(app: "pin.enter")
                    .font(TypeLevel.footer.font)
                    .settingsFont(isFocused: focus == Self.buttonID)
                    .settingsSurface(.pill, isFocused: focus == Self.buttonID)
            }
            .bareFocusableButton()
            .focused($focus, equals: Self.buttonID)
            .padding(.top, 34)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .preference(key: SettingsFirstEntryKey.self, value: Self.buttonID)
        .onChange(of: entryRequest) { _, _ in focus = Self.buttonID }
    }
}
