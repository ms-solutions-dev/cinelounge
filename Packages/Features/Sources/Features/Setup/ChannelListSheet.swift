import Core
import DesignSystem
import Flows
import SwiftUI

/// The IPTV sheet of A4 — **the existing form, inside the setup** (AP88 §3).
///
/// The fields and the check are ``PlaylistLoginView``'s; what is accepted and how it is checked
/// stays with whoever passes ``accept`` (`PlaylistAccounts.accept` in the app target, which
/// writes the list into the active profile — the setup's profile, §1.4 point 1). This view adds
/// only the head and the way back into the journey.
public struct ChannelListSheet: View {

    let journey: SetupJourney
    /// Accepts and checks an access — a language key on failure, `nil` on success.
    let accept: @MainActor (PlaylistAccess) async -> String?

    public init(journey: SetupJourney, accept: @escaping @MainActor (PlaylistAccess) async -> String?) {
        self.journey = journey
        self.accept = accept
    }

    public var body: some View {
        SetupSheetFrame(title: profileTitle) {
            VStack(alignment: .leading, spacing: 24) {
                if !journey.machine.isOnline {
                    SetupNote(text: Text(app: "setup.channelList.offline"))
                }
                PlaylistLoginView(
                    onSubmit: submit, onCancel: { journey.send(.abort) },
                    kinds: Self.kinds(online: journey.machine.isOnline))
            }
        }
        .onExitCommand { journey.send(.abort) }
    }

    /// **Only M3U without a network** (AP88 §2.4) — Xtream checks the account at the provider.
    nonisolated static func kinds(online: Bool) -> [PlaylistAccess.Kind] {
        online ? PlaylistAccess.Kind.allCases : [.m3u]
    }

    private var profileTitle: String {
        guard case .channelList(let identifier) = journey.state,
            let profile = journey.machine.setupProfile(identifier)
        else { return "IPTV" }
        return profile.sheetTitle("IPTV")
    }

    private func submit(_ access: PlaylistAccess) async -> String? {
        let failure = await accept(access)
        if failure == nil {
            journey.send(.sourceFinished(.channelList, .done(detail: Self.detail(for: access))))
        }
        return failure
    }

    /// What the row says after ✓ — **the provider's host**, as the list is named
    /// (`PlaylistAccounts`). An Xtream address is usually typed without a scheme.
    nonisolated static func detail(for access: PlaylistAccess) -> String {
        let address = access.address.trimmingCharacters(in: .whitespacesAndNewlines)
        let withScheme = address.contains("://") ? address : "http://" + address
        return URL(string: withScheme)?.host() ?? address
    }
}
