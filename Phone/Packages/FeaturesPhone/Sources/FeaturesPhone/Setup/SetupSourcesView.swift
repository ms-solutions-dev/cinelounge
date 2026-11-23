import Core
import DesignSystemPhone
import Flows
import ProfileKit
import SwiftUI

/// A4 — **"What does Lea watch?": Jellyfin, IPTV and CL-Server for one profile** (AP88 §1.2).
///
/// **The same rows as on the TV, with the same states and sentences** (``Flows/SourceRowState``,
/// the TV's `SourcesView.Look`): ✓ for done, "Found" in gold, "From your profile · just confirm",
/// "Take over the lists from Lea", "No network". A tap is ``Flows/SetupInput/openSource(_:)``;
/// what follows — notice, sheet, one-tap copy — the machine decides.
///
/// **"Done" stays visible without a source**, dimmed and answering with nothing, under the
/// sentence "One is enough" (§1.4 point 5) — the TV's rule; a missing button would leave open
/// where the way out is.
struct SetupSourcesView: View {

    /// How a row looks — **a value, so that the checks read the decision without a screen**, and
    /// the same cases as on the TV.
    struct Look: Equatable, Sendable {

        /// The line under the source's name.
        enum Caption: Equatable, Sendable {
            case empty(Access.Kind)
            case foundOn(String)
            case fromProfile(user: String, host: String)
            case suggested(from: String)
            case copied(from: String)
            /// IPTV lists of the profile already lie on this device.
            case ready
            case detail(String)
            case waiting
            case noNetwork
            case notForChildren
        }

        /// The mark at the end of the row.
        enum Badge: Equatable, Sendable {
            case add
            case found
            case confirm
            case takeOver
            case done
            case waiting
            case unavailable
        }

        let caption: Caption
        let badge: Badge
    }

    let page: SourcesPage
    let profile: SetupProfile?
    /// The profile whose IPTV lists this one took over (``Flows/SetupMachine/listsCopied(for:)``).
    let copiedFrom: String?
    let send: (SetupInput) -> Void

    /// The look of one row — **every state the machine knows has its own sentence.**
    nonisolated static func look(_ kind: Access.Kind, _ state: SourceRowState, copiedFrom: String?) -> Look {
        switch state {
        case .empty: Look(caption: .empty(kind), badge: .add)
        case .found(let detail): Look(caption: .foundOn(detail), badge: .found)
        case .fromProfile(let access):
            if case .jellyfin(let server, _, let username) = access {
                Look(
                    caption: .fromProfile(user: username, host: server.host() ?? server.absoluteString),
                    badge: .confirm)
            } else {
                Look(caption: .empty(kind), badge: .confirm)
            }
        case .suggested(let donor): Look(caption: .suggested(from: donor), badge: .takeOver)
        case .done(let detail):
            if kind == .channelList, let copiedFrom {
                Look(caption: .copied(from: copiedFrom), badge: .done)
            } else if detail.isEmpty {
                Look(caption: kind == .channelList ? .ready : .detail(""), badge: .done)
            } else {
                Look(caption: .detail(detail), badge: .done)
            }
        case .waiting: Look(caption: .waiting, badge: .waiting)
        case .unavailable(.noNetwork): Look(caption: .noNetwork, badge: .unavailable)
        case .unavailable(.notForChildren): Look(caption: .notForChildren, badge: .unavailable)
        }
    }

    /// The key of a caption — **the TV's keys** (`setup.sources.*`, `setup.clServer.*`); `nil` for a
    /// detail, which is the provider's or the server's own name.
    nonisolated static func captionKey(_ caption: Look.Caption) -> String? {
        switch caption {
        case .empty(.jellyfin): "setup.sources.jellyfinEmpty"
        case .empty(.channelList): "setup.sources.channelListEmpty"
        case .empty(.portals): "setup.clServer.askTitle"
        case .foundOn: "setup.sources.foundOn %@"
        case .fromProfile: "setup.sources.fromProfile %@ %@"
        case .suggested: "setup.sources.suggested %@"
        case .copied: "setup.sources.copied %@"
        case .ready: "setup.sources.ready"
        case .detail: nil
        case .waiting: "setup.clServer.waiting"
        case .noNetwork: "setup.sources.noNetwork"
        case .notForChildren: "setup.clServer.childTitle"
        }
    }

    nonisolated static func badgeKey(_ badge: Look.Badge) -> String {
        switch badge {
        case .found: "setup.sources.found"
        case .confirm: "setup.sources.confirm"
        case .takeOver: "setup.sources.takeOver"
        default: "setup.sources.add"
        }
    }

    nonisolated static func sourceName(_ kind: Access.Kind) -> String {
        switch kind {
        case .jellyfin: "Jellyfin"
        case .channelList: "IPTV"
        case .portals: "CL-Server"
        }
    }

    nonisolated static func glyph(_ kind: Access.Kind) -> Glyph {
        switch kind {
        case .jellyfin: .server
        case .channelList: .channelList
        case .portals: .portal
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MetricsBoard.phone.gutter) {
                Text(verbatim: AppLanguageSetting.text("setup.sources.head \(name)"))
                    .font(TypeLevel.label.font)
                    .foregroundStyle(ColorRole.textMatt.color)
                header
                VStack(spacing: 10) {
                    ForEach(page.rows, id: \.kind) { row in
                        rowView(row)
                    }
                }
                .padding(.top, 4)
                if page.rows.contains(where: { $0.state == .unavailable(.noNetwork) }) {
                    Footnote(message: "setup.sources.noNetworkHint")
                }
                footer
                    .padding(.top, MetricsBoard.phone.gutter)
            }
            .padding(.horizontal, MetricsBoard.phone.margin)
            .padding(.bottom, MetricsBoard.phone.section)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var name: String { profile?.profile.name ?? "" }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                if let profile = profile?.profile {
                    ProfileCircle(
                        letter: profile.initial, avatar: profile.avatar, edge: 44,
                        font: TypeLevel.header.font, letterColor: ColorRole.reason.color,
                        surface: ProfileColor.tag(profile.color.rawValue) ?? ColorRole.surfaceHigh.color)
                }
                Text(verbatim: AppLanguageSetting.text("setup.sources.title \(name)"))
                    .font(TypeLevel.title.font)
                    .foregroundStyle(ColorRole.text.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Footnote(message: "setup.sources.intro")
        }
    }

    // MARK: - Rows

    private func rowView(_ row: SourceRow) -> some View {
        let look = Self.look(row.kind, row.state, copiedFrom: copiedFrom)
        return VStack(alignment: .trailing, spacing: 6) {
            Button {
                send(.openSource(row.kind))
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: Self.glyph(row.kind).name)
                        .font(TypeLevel.header.font)
                        .foregroundStyle(ColorRole.textMatt.color)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: Self.sourceName(row.kind))
                            .font(TypeLevel.header.font)
                            .foregroundStyle(ColorRole.text.color)
                        caption(look.caption)
                            .font(TypeLevel.label.font)
                            .foregroundStyle(ColorRole.textMatt.color)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 8)
                    badge(look.badge)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    ColorRole.surface.color,
                    in: RoundedRectangle(cornerRadius: MetricsBoard.phone.fieldRadius)
                )
                .opacity(row.state == .unavailable(.noNetwork) ? 0.55 : 1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if look.badge == .takeOver {
                Button {
                    send(.addOwnChannelList)
                } label: {
                    Text(app: "setup.sources.ownList")
                }
                .buttonStyle(.quiet)
            }
        }
    }

    @ViewBuilder
    private func caption(_ caption: Look.Caption) -> some View {
        switch caption {
        case .foundOn(let detail): Text(app: "setup.sources.foundOn \(detail)")
        case .fromProfile(let user, let host): Text(app: "setup.sources.fromProfile \(user) \(host)")
        case .suggested(let donor): Text(app: "setup.sources.suggested \(donor)")
        case .copied(let donor): Text(app: "setup.sources.copied \(donor)")
        case .detail(let detail): Text(verbatim: detail)
        default: Text(appKey: Self.captionKey(caption) ?? "")
        }
    }

    @ViewBuilder
    private func badge(_ badge: Look.Badge) -> some View {
        switch badge {
        case .done:
            Image(systemName: Glyph.done.pair.filled)
                .font(TypeLevel.header.font)
                .foregroundStyle(ColorRole.brandLight.color)
                .accessibilityLabel(Text(app: "common.done"))
        case .waiting:
            Image(systemName: Glyph.pending.name)
                .font(TypeLevel.header.font)
                .foregroundStyle(ColorRole.textMatt.color)
                .accessibilityLabel(Text(app: "setup.clServer.waiting"))
        case .unavailable:
            EmptyView()
        case .add, .found, .confirm, .takeOver:
            let tint = badge == .found ? ColorRole.brandLight.color : ColorRole.textMatt.color
            Text(appKey: Self.badgeKey(badge))
                .font(TypeLevel.label.font)
                .foregroundStyle(tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .overlay(Capsule().stroke(tint, lineWidth: 1))
        }
    }

    // MARK: - Done

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !page.canFinish {
                Footnote(message: "setup.sources.oneIsEnough")
            }
            Button {
                send(.finishSources)
            } label: {
                Text(app: "common.done").frame(maxWidth: .infinity)
            }
            .buttonStyle(.loud)
            .opacity(page.canFinish ? 1 : 0.45)
        }
    }
}
