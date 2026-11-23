import DesignSystemPhone
import SwiftUI

/// About → Privacy — **the explanation that has to exist.**
///
/// **App Store guideline 5.1.1(i) demands it explicitly *"within the app in an easily
/// accessible manner"***, not just as a link in App Store Connect. Until 2026-09-07 not a
/// word of it appeared in the whole source code, and no key in the language catalog.
///
/// **It is short because there is little to explain — and that is the content.** This app has
/// no service behind it: there is no CineLounge account, no CineLounge server and
/// nobody who collects anything. What it does is turn to **third-party** services
/// that the viewer has entered themselves. The only honest explanation
/// is therefore an enumeration: **where does something go, what stays here, and how do you get rid of it.**
///
/// **The three sections stand in exactly this order**, because that is the order of the
/// questions: first "who gets my data", then "what is on the device", then
/// "how do I get rid of it". Whoever comes with the third question finds it at the bottom and not
/// between two paragraphs.
///
/// **No advertising, no analytics, no third-party identifiers** — that stands here as a
/// sentence and is true: the app includes seven third-party packages, all through the Jellyfin SDK, and
/// none of them reports anywhere. Whoever changes that changes this screen too.
struct PrivacyView: View {
    @Environment(\.horizontalSizeClass) private var widthClass

    /// The way to storage — **the answer to "how do I get rid of it" is a place and
    /// not a paragraph.** An explanation that only describes deleting is
    /// homework; here the button stands next to it.
    let storage: () -> Void

    var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()

            ScrollSurface {
                VStack(alignment: .leading, spacing: 0) {
                    section("privacy.who", "privacy.whoText")
                    section("privacy.where", "privacy.whereText")
                    section("privacy.what", "privacy.whatText")

                    SettingsCard(header: "privacy.delete") {
                        DisclosureRow(
                            title: "settings.speicher", icon: Glyph.downloads.name,
                            isContained: true, action: storage)
                    }
                    Footnote(message: "privacy.deleteText")
                }
                .contentColumn(widthClass)
                .padding(.top, MetricsBoard.phone.gutter)
            }
        }
    }

    /// **A section is a head and a sentence, not a card.** Running text in a card
    /// reads as a control; there is nothing to operate here.
    private func section(_ header: String, _ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: header)
            Text(appKey: message)
                .font(TypeLevel.footer.font)
                .foregroundStyle(ColorRole.textMatt.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, MetricsBoard.phone.margin)
        }
        .padding(.bottom, MetricsBoard.phone.section)
    }
}

/// About → Report channel or title.
///
/// **Guideline 1.2 demands a reporting path for user-generated content** — and the
/// honest answer here is a different one from that of a service with its own catalog: what
/// comes in comes from **the viewer's own list**. Nobody
/// published it, and nobody can withdraw it; we have no catalog from which
/// anything could be removed.
///
/// **That is why what stands here is what really helps, and not a form into a queue that
/// does not exist:** hide the channel, hide the group, switch on parental controls
/// — and the address you can write to when the app itself does something
/// wrong.
struct ReportView: View {
    @Environment(\.horizontalSizeClass) private var widthClass

    let groups: () -> Void
    let parentalControls: () -> Void

    var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()

            ScrollSurface {
                VStack(alignment: .leading, spacing: 0) {
                    Footnote(message: "report.text")
                        .padding(.bottom, MetricsBoard.phone.section)

                    SettingsCard(header: "report.yourself") {
                        DisclosureRow(
                            title: "live.groups", icon: Glyph.live.name,
                            isContained: true, action: groups)
                        Separator(isIndented: true)
                        DisclosureRow(
                            title: "settings.kindersicherung", icon: Glyph.kind.name,
                            isContained: true, action: parentalControls)
                    }

                    SectionHeader(title: "about.contact")
                    Footnote(message: "report.contactText")
                }
                .contentColumn(widthClass)
                .padding(.top, MetricsBoard.phone.gutter)
            }
        }
    }
}
