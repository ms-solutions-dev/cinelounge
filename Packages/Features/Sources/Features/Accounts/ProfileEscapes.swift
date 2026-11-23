import Core
import DesignSystem
import ProfileKit
import SwiftUI

extension Notification.Name {

    /// Something has happened at the "Forgot PIN" way out — here or remotely.
    ///
    /// **The shell sets ``ProfileKit/ProfileCloud/pinEscape`` once and reports it through here**
    /// (`CloudStartup`). The cloud's callback has exactly one place; the places that show an
    /// open request are several — switcher, management, PIN sheets.
    public static let pinEscape = Notification.Name("cinelounge-pinausweg")
}

/// The open "Forgot PIN" requests **per profile**, as this device sees them
/// (cross-check strand C, finding 6).
///
/// **The finding:** The way out per profile (``ProfileKit/PINFallback/Lock/profile(_:)``) expired after
/// 24 hours without anyone seeing it. The request of the parental controls stands on its
/// PIN sheet (``PinDeadlineRow``), that of a profile stood nowhere — not on the circle, not
/// in the management, not at the door of the parental controls. Whoever had not made it themselves
/// learned of it only when the PIN was gone.
///
/// **A value and not a view**, so that the switcher, the management and the PIN sheets read the same
/// list and the check can recompute it without a screen.
struct ProfileEscapes: Equatable {

    struct ContentEntryRecord: Equatable, Identifiable {
        let identifier: Profile.Identifier
        let name: String
        let state: PINFallback.State
        var id: String { identifier.rawValue }
    }

    /// In the order of the book — requests for profiles that do not exist here drop out.
    let entries: [ContentEntryRecord]

    static let none = ProfileEscapes(entries: [])

    init(entries: [ContentEntryRecord]) { self.entries = entries }

    init(pending: [Profile.Identifier: PINFallback.State], profile profileName: [Profile]) {
        entries = profileName.compactMap { profile in
            guard let state = pending[profile.identifier], state.pending else { return nil }
            return ContentEntryRecord(identifier: profile.identifier, name: profile.name, state: state)
        }
    }

    /// Reads the requests from the cloud — without the cloud there are none.
    static func read(cloud: ProfileCloud?, profile: [Profile]) -> ProfileEscapes {
        guard let cloud else { return .none }
        return ProfileEscapes(pending: cloud.openProfileRecoveries(), profile: profile)
    }

    func state(forItem identifier: Profile.Identifier) -> PINFallback.State? {
        entries.first { $0.identifier == identifier }?.state
    }

    var isEmpty: Bool { entries.isEmpty }
}

/// The marker on the circle in "Who is watching?" — **information only, no button.** Whoever just
/// wants to watch should not be held up by a management question; cancelling
/// happens in the management and on the PIN sheets. The same split as with
/// "Merge?".
struct ProfileEscapeMarker: View {

    var body: some View {
        Label {
            Text(app: "profiles.pinResetMark")
        } icon: {
            Image(systemName: Glyph.toBackfill.name)
        }
        .font(TypeLevel.lowercased.font)
        .foregroundStyle(ColorRole.progress.color)
    }
}

/// One row per open request — **with "Cancel request" if the place allows it.**
///
/// **Cancelling needs no PIN** (see ``ProfileKit/ProfileCloud/cancelPinRecovery(forItem:)``):
/// It is the cautious direction, and the most likely requester is not the
/// forgetful adult but the child who has found the button.
struct ProfileEscapeRows: View {

    let escapes: ProfileEscapes
    /// `nil` means: only show — for example above a number pad, where another button would
    /// pull focus away from the block.
    var cancel: ((Profile.Identifier) -> Void)?

    @FocusState private var focus: String?

    var body: some View {
        if !escapes.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(escapes.entries) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 18) {
                        row(entry)
                            .font(TypeLevel.footer.font)
                            .foregroundStyle(ColorRole.progress.color)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 760, alignment: .leading)
                        // **The existing button and no new surface** — see
                        // `SettingsRowsTests`: No hand-built surface should be added
                        // in `Konten/`.
                        if let cancel {
                            FormButton(
                                title: "profiles.pinResetCancel", rank: .beside, warning: true,
                                identifier: entry.id, focus: $focus
                            ) {
                                cancel(entry.identifier)
                            }
                        }
                    }
                    .focusSection()
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ entry: ProfileEscapes.ContentEntryRecord) -> some View {
        switch entry.state {
        case .isRunning(let due, let device):
            HStack(spacing: 8) {
                Text(app: "profiles.pinResetRunning \(entry.name) \(device)")
                Text(timerInterval: Date()...max(Date(), due), countsDown: true)
            }
        case .due(let device), .confirmed(let device):
            Text(app: "profiles.pinResetReady \(entry.name) \(device)")
        case .wartetAufServer:
            Text(app: "profiles.pinResetWaiting \(entry.name)")
        case .none:
            EmptyView()
        }
    }
}

/// Heading and rows with "Cancel request" — **self-contained**, so that the
/// parental controls, the management and the way-out screen show the same section
/// without ever reading cloud and book themselves.
///
/// **It re-reads when something happens at the way out** (``Foundation/Notification/Name/pinEscape``):
/// A request that is made or cancelled on the phone would otherwise stand there wrong until the next
/// opening.
struct ProfileEscapeSection: View {

    var cloud: ProfileCloud? = ProfileCloud.attached
    var store: any KeyValueStore = FileStore()

    @State private var escapes = ProfileEscapes.none

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !escapes.isEmpty {
                Text(app: "profiles.pinResetTitle")
                    .font(TypeLevel.header.font)
                    .foregroundStyle(ColorRole.text.color)
                ProfileEscapeRows(escapes: escapes) { identifier in
                    cloud?.cancelPinRecovery(forItem: .profile(identifier))
                    read()
                }
            }
        }
        .padding(.bottom, escapes.isEmpty ? 0 : 30)
        .onAppear(perform: read)
        .onReceive(NotificationCenter.default.publisher(for: .pinEscape)) { _ in read() }
    }

    private func read() {
        escapes = ProfileEscapes.read(cloud: cloud, profile: ProfileBook.read(from: store).profile)
    }
}
