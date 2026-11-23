import Core
import DesignSystemPhone
import Flows
import ProfileKit
import SwiftUI

/// A1 on the phone — **"Looking at iCloud …", short and skippable** (AP88 §1.1, G4).
///
/// The TV covers the wait with its intro clip; the phone has none
/// (``Flows/SetupSteps/coversIntro``), so the deadline runs from the start and this page stands
/// for at most ``Flows/SetupMachine/cloudGrace``. **"Skip" is the deadline by hand:** A2 comes
/// without iCloud, and a late answer still adds its cards there (§2.6).
struct SetupWaitView: View {

    let skip: () -> Void

    var body: some View {
        VStack(spacing: MetricsBoard.phone.section) {
            Spacer(minLength: 0)
            BrandMark()
            HStack(spacing: 10) {
                ProgressView()
                Text(app: "setup.cloudWait")
                    .font(TypeLevel.footer.font)
                    .foregroundStyle(ColorRole.textMatt.color)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            Button(action: skip) {
                Text(app: "setup.cloudWait.skip")
            }
            .buttonStyle(.quiet)
            .padding(.bottom, MetricsBoard.phone.section)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, MetricsBoard.phone.margin)
    }
}

/// A2 — **"Who's watching here?"**: the profiles iCloud brought, "New profile", and the way to a
/// profile on another device (AP88 §2; replaces the path choice of AP21).
///
/// **The same offer as on the TV** (``Flows/WelcomeOffer``): a child from iCloud stands greyed out
/// as long as this device has no household PIN, with the same quiet sentence; a late iCloud answer
/// adds cards at the end, so that nothing moves under the thumb (§2.6).
///
/// **The camera instead of the code** (``Flows/SetupSteps/FetchFromPhone/scan``): the TV shows a QR
/// and waits; the phone scans the code another device shows under "Devices & Sharing". That
/// works only through iCloud (``Flows/WelcomeOffer/canFetch``) — without it the row stays, greyed,
/// so that nobody looks for it after signing in to iCloud.
struct SetupWelcomeView: View {

    let offer: WelcomeOffer
    let send: (SetupInput) -> Void

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 16, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MetricsBoard.phone.gutter) {
                BrandMark()
                    .padding(.top, MetricsBoard.phone.section)

                Text(app: "setup.welcome.title")
                    .font(TypeLevel.title.font)
                    .foregroundStyle(ColorRole.text.color)
                    .padding(.top, MetricsBoard.phone.gutter)

                Text(appKey: Self.subtitle(for: offer))
                    .font(TypeLevel.footer.font)
                    .foregroundStyle(ColorRole.textMatt.color)
                    .fixedSize(horizontal: false, vertical: true)

                LazyVGrid(columns: columns, alignment: .leading, spacing: MetricsBoard.phone.gutter) {
                    ForEach(offer.cards, id: \.profile.id) { card in
                        profileCard(card)
                    }
                    newProfileCard
                }
                .padding(.top, MetricsBoard.phone.gutter)

                if offer.asksForAdultFirst {
                    Footnote(message: "setup.welcome.adultFirst")
                }

                fetchButton
                    .padding(.top, MetricsBoard.phone.gutter)
            }
            .padding(.horizontal, MetricsBoard.phone.margin)
            .padding(.bottom, MetricsBoard.phone.section)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func profileCard(_ card: WelcomeOffer.Card) -> some View {
        let profile = card.profile.profile
        return Button {
            send(.chose(profile.identifier))
        } label: {
            VStack(spacing: 8) {
                ProfileCircle(
                    letter: profile.initial, avatar: profile.avatar, edge: MetricsBoard.phone.person,
                    font: TypeLevel.section.font, letterColor: ColorRole.reason.color,
                    surface: ProfileColor.tag(profile.color.rawValue) ?? ColorRole.surfaceHigh.color)
                Text(verbatim: profile.name)
                    .font(TypeLevel.footer.font)
                    .foregroundStyle(ColorRole.text.color)
                    .lineLimit(1)
                if profile.kind == .kind {
                    Label {
                        Text(app: "profiles.child")
                    } icon: {
                        Image(systemName: Glyph.kind.name)
                    }
                    .font(TypeLevel.label.font)
                    .foregroundStyle(ColorRole.textMatt.color)
                }
            }
            .frame(maxWidth: .infinity)
            .opacity(card.selectable ? 1 : 0.4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!card.selectable)
    }

    private var newProfileCard: some View {
        Button {
            send(.choseNew)
        } label: {
            VStack(spacing: 8) {
                Image(systemName: Glyph.add.name)
                    .font(TypeLevel.section.font)
                    .foregroundStyle(ColorRole.textMatt.color)
                    .frame(width: MetricsBoard.phone.person, height: MetricsBoard.phone.person)
                    .background(ColorRole.surface.color, in: Circle())
                Text(app: "setup.welcome.newProfile")
                    .font(TypeLevel.footer.font)
                    .foregroundStyle(ColorRole.text.color)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var fetchButton: some View {
        Button {
            send(.choseFetchFromPhone)
        } label: {
            Label {
                Text(app: "setup.welcome.scan")
            } icon: {
                Image(systemName: Glyph.camera.name)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.quiet)
        .disabled(!offer.canFetch)
    }

    /// The sentence under the title — **the same choice as on the TV** (`WelcomeView.subtitle`).
    nonisolated static func subtitle(for offer: WelcomeOffer) -> String {
        if !offer.cloud.profiles.isEmpty { return "setup.welcome.fromCloud" }
        return offer.cards.isEmpty ? "setup.welcome.fresh" : "setup.welcome.known"
    }
}
