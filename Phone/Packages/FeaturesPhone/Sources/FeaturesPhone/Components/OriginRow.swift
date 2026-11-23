import DesignSystemPhone
import SwiftUI

/// Where a configured value comes from — **and how far it reaches.**
///
/// **The market finding of 2026-09-07** Four research passes over Swiftfin, Streamyfin, Infuse,
/// Plex and the IPTV clients reached the same conclusion: the most common complaint about
/// such apps is **not** "setting not found" but **"setting applied, has no effect"** —
/// documented dozens of times in the issue trackers of Swiftfin and Streamyfin. Of all apps
/// examined, exactly one has a precedence chain at all, and it lives there in the source code
/// and not on the screen.
///
/// **What this line expressly does NOT say.** "Set by the server" would have been the obvious
/// choice — the Jellyfin user policy can cap a bitrate, and the provider dictates its
/// streams. **This app does not read the user policy today.** A line that claims a server
/// requirement without ever having queried it would be a lie in the UI — and the worst kind,
/// because it stands exactly where someone is looking for an explanation. It comes when the
/// query comes, and not a day earlier.
///
/// **What it says instead has been checked against the source.** ``SetupBundle``
/// lists exactly what travels along on a device handoff (E5): media server, channel lists,
/// bridge, the two rating keys, **language, color theme**, shelf order, sports, group order
/// and parental controls. Everything else stays here — **including the subtitle size and the
/// original audio**, which live in `@AppStorage`. That is exactly the information the viewer
/// otherwise lacks: they set something on the phone, set up the next device and do not find
/// it there again.
enum Origin {

    /// Stays on this device. Not in the handoff bundle.
    case device

    /// Belongs to the **profile** and travels with it to every device that carries it (iCloud).
    ///
    /// **Since 2026-09-25** (tvOS roadmap AP46): sound preference, subtitles and app language
    /// live in the person's compartment. "Applies only on this device" was no longer true for
    /// them.
    case profile

    /// Travels along on a device handoff — ``SetupBundle`` lists it.
    case handoff

    /// The service decides, the app cannot.
    ///
    /// **Only where it is true and documented**: the provider delivers exactly one stream per
    /// channel (measured: `catchup = 0` for all 7,746, one resolution per identifier), and the
    /// bridge orders the hosts itself and works through them one after another.
    case service

    var message: String {
        switch self {
        case .device: "origin.device"
        case .profile: "origin.profile"
        case .handoff: "origin.handover"
        case .service: "origin.service"
        }
    }

    /// **A dot and not color alone.** `GESTALTUNG.md` §1 forbids color as the sole carrier; here
    /// the sentence always stands next to it, and the dot is the second encoding — not the first.
    @MainActor
    var color: Color {
        switch self {
        case .device: ColorRole.textQuiet.color
        case .profile: ColorRole.success.color
        case .handoff: ColorRole.success.color
        case .service: ColorRole.progress.color
        }
    }
}

extension View {

    /// Attaches the origin line below a setting.
    ///
    /// **Sparingly and not on every row.** Almost everything in this area lives on the device; if
    /// it stood everywhere, it would be wallpaper and nobody would read it. It belongs where the
    /// answer **surprises** — and that is the case in which someone sets something and does not
    /// find it again on the second device.
    func origin(_ origin: Origin) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            self
            OriginMark(origin: origin)
        }
    }
}

/// Dot and sentence — **and the inset comes from the environment.**
///
/// **The finding of 2026-09-07, seen in the simulator:** the mark stuck to the left screen edge
/// while the sentence above it indented 20 points. The reason: ``origin(_:)`` attaches it
/// **below** the finished view, and that view's inset is baked into it — it applies to it and
/// not to the mark beside it. It is a view of its own because only a view can read its inset
/// from ``SwiftUI/EnvironmentValues/rowInset``; in a card it sits differently than on the
/// background.
struct OriginMark: View {

    let origin: Origin

    @Environment(\.rowInset) private var inset

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(origin.color)
                .frame(width: 5, height: 5)
            Text(appKey: origin.message)
                .font(TypeLevel.lowercased.font)
                .foregroundStyle(ColorRole.textQuiet.color)
        }
        .padding(.horizontal, inset)
        .accessibilityElement(children: .combine)
    }
}
