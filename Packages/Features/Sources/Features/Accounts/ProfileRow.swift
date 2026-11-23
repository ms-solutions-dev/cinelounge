import Core
import DesignSystem
import ProfileKit
import SwiftUI

/// A profile in the list: circle in its color, name, kind — and what belongs to it.
///
/// **The successor of ``AccountRow``, and the reasoning moves with it.** A
/// child profile differs in **shape**, not in color: Red against olive
/// stands at 1.02 : 1 for deuteranopia (E47), and from three meters every
/// color difference becomes smaller, never larger. The row therefore carries a **symbol and a
/// word**.
///
/// **What is new is the second line.** For the account the server stood there — a
/// piece of information that always existed, because without a server there was no account. A profile can have three
/// paths, one or none; the line says **which**, because exactly that is from AP41 on
/// the question one has in front of a profile circle.
struct ProfileRow: View {

    let profile: Profile
    /// Ob dieses Profil gerade davorsitzt.
    let isActive: Bool
    /// Whether the row has focus. **Passed in and not measured itself:** The list
    /// keeps a single `@FocusState`, and two truths about the same focus
    /// drift apart as soon as a row disappears.
    let hasFocus: Bool

    var body: some View {
        HStack(spacing: 26) {
            profileCircle

            VStack(alignment: .leading, spacing: 4) {
                Text(profile.name)
                    .font(TypeLevel.header.font)
                    .foregroundStyle(hasFocus ? ColorRole.reason.color : ColorRole.text.color)

                HStack(spacing: 10) {
                    if profile.kind == .kind {
                        Label {
                            Text(app: "profiles.child")
                        } icon: {
                            Image(systemName: "figure.child")
                        }
                        Text(verbatim: "·")
                    }
                    accessRow
                }
                .font(TypeLevel.lowercased.font)
                .foregroundStyle(
                    hasFocus ? ColorRole.reason.color.opacity(0.7) : ColorRole.textQuiet.color
                )
            }

            Spacer(minLength: 20)

            if isActive {
                Label {
                    Text(app: "profiles.active")
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                }
                .font(TypeLevel.lowercased.font)
                .foregroundStyle(hasFocus ? ColorRole.reason.color : ColorRole.brandLight.color)
            }
        }
        .settingsSurface(.row, isFocused: hasFocus)
    }

    /// What belongs to this profile — **and "nothing yet" if it is nothing.**
    ///
    /// An empty line would look like one that is still loading. A profile without an access is
    /// valid (one creates it before giving it anything); the sentence says that nothing
    /// is missing here, but that nothing has been entered yet.
    @ViewBuilder private var accessRow: some View {
        if profile.credentials.isEmpty {
            Text(app: "profiles.noAccess")
        } else {
            Text(verbatim: split.joined(separator: " · "))
        }
    }

    private var split: [String] {
        var rows: [String] = []
        if let name = profile.jellyfin?.displayName { rows.append(name) }
        let listen = profile.channelLists.count
        if listen > 0 {
            rows.append(AppLanguageSetting.text("profiles.playlistCount \(listen)"))
        }
        if profile.wantsPortals {
            rows.append(AppLanguageSetting.text("tab.portals"))
        }
        return rows
    }

    /// The circle with the initial in the profile's color — **or with its
    /// picture** (AP49).
    ///
    /// **Not the Jellyfin picture:** Jellyfin keeps some, but not every user has
    /// one — and a placeholder picture next to a real one looks like a loading error. A
    /// profile without Jellyfin would have none anyway. The picture here is one of the sixteen
    /// bundled motifs, and every profile has them to choose from.
    ///
    /// **With a picture no frame in focus:** Here the whole row carries focus as a light
    /// surface; the circle swaps its color only so that it does not disappear on it. A
    /// picture does not disappear on a light surface.
    private var profileCircle: some View {
        ProfileCircle(
            letter: profile.initial,
            avatar: profile.avatar,
            edge: 68,
            font: TypeLevel.section.font,
            letterColor: hasFocus ? ColorRole.text.color : ColorRole.reason.color,
            surface: hasFocus ? ColorRole.reason.color : ProfileColor.tag(profile.color.rawValue),
            frame: nil)
    }
}
