import Core
import DesignSystem
import Flows
import ProfileKit
import SwiftUI

/// A4 — **"What does Lea watch?": Jellyfin, IPTV and CL-Server for one profile** (AP88 §1.2,
/// design A of 2026-11-15).
///
/// Every row shows its state as the machine computed it (``Flows/SourceRowState``) — ✓ for done,
/// "Found" in gold, "Add" when empty — and a press is the input ``Flows/SetupInput/openSource(_:)``;
/// what follows (notice, sheet, one-press copy) the machine decides. **The focus goes to the first
/// open row** (``Flows/SourcesPage/focus``), so that it stands on the next source after a sheet.
///
/// **"Done" is always reachable and never disabled** — a disabled button drops out of the focus
/// tree on tvOS. Without a source it answers with nothing and the sentence "One is enough" says
/// why (§1.4 point 5).
struct SourcesView: View {

    /// How a row looks — **a value, so that the checks read the decision without a screen.**
    nonisolated struct Look: Equatable, Sendable {

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

    @FocusState private var focus: String?

    nonisolated static let doneID = "fertig"
    nonisolated static let ownListID = "eigene-liste"

    nonisolated static func rowID(_ kind: Access.Kind) -> String { "quelle-" + kind.rawValue }

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

    /// Where the focus goes — the first open row, else "Done".
    nonisolated static func focusTarget(_ page: SourcesPage) -> String {
        page.focus.map(rowID) ?? doneID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SetupStepHead(stage: .sources, title: AppLanguageSetting.text("setup.sources.head \(name)"))
            header
                .padding(.top, 48)
            VStack(alignment: .leading, spacing: 16) {
                ForEach(page.rows, id: \.kind) { row in
                    rowView(row)
                }
            }
            .padding(.top, 40)
            .focusSection()
            if page.rows.contains(where: { $0.state == .unavailable(.noNetwork) }) {
                SetupNote(text: Text(app: "setup.sources.noNetworkHint"))
                    .padding(.top, 24)
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(.horizontal, MetricsBoard.tv.margin)
        .padding(.vertical, TVMetrics.topMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: Self.focusTarget(page), initial: true) { _, target in focus = target }
        .onExitCommand { send(.back) }
    }

    private var name: String { profile?.profile.name ?? "" }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 24) {
                if let profile = profile?.profile {
                    ProfileCircle(
                        letter: profile.initial,
                        avatar: profile.avatar,
                        edge: 72,
                        font: TypeLevel.header.font,
                        letterColor: ColorRole.reason.color,
                        surface: ProfileColor.tag(profile.color.rawValue),
                        frame: nil)
                }
                Text(app: "setup.sources.title \(name)")
                    .font(TypeLevel.section.font)
                    .foregroundStyle(ColorRole.text.color)
            }
            SetupNote(text: Text(app: "setup.sources.intro"))
        }
    }

    // MARK: - Rows

    private func rowView(_ row: SourceRow) -> some View {
        let look = Self.look(row.kind, row.state, copiedFrom: copiedFrom)
        let id = Self.rowID(row.kind)
        let hasFocus = focus == id
        return HStack(spacing: 20) {
            Button {
                send(.openSource(row.kind))
            } label: {
                HStack(spacing: 28) {
                    Image(systemName: Self.glyph(row.kind).name)
                        .font(TypeLevel.header.font)
                        .frame(width: 56)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: Self.sourceName(row.kind))
                            .font(TypeLevel.header.font)
                        Self.captionText(look.caption)
                            .font(TypeLevel.lowercased.font)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 20)
                    badge(look.badge, focused: hasFocus)
                }
                .foregroundStyle(hasFocus ? ColorRole.reason.color : ColorRole.text.color)
                .padding(.horizontal, 34)
                .padding(.vertical, 22)
                .background(
                    hasFocus ? ColorRole.text.color : ColorRole.surface.color,
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                )
                .opacity(look.badge == .unavailable && row.state == .unavailable(.noNetwork) ? 0.55 : 1)
            }
            .bareFocusableButton()
            .info(Text(verbatim: Self.sourceName(row.kind) + ", ") + Self.captionText(look.caption))
            .focused($focus, equals: id)
            .focusHighlight(hasFocus, scale: 1.02, accent: ColorRole.brandLight.color)
            .frame(maxWidth: 1300)

            if look.badge == .takeOver {
                SetupButton(title: "setup.sources.ownList", identifier: Self.ownListID, focus: $focus) {
                    send(.addOwnChannelList)
                }
            }
        }
    }

    /// The sentence under a source's name — **shared with A7**, so that a source reads the same
    /// on both pages.
    static func captionText(_ caption: Look.Caption) -> Text {
        switch caption {
        case .empty(.jellyfin): Text(app: "setup.sources.jellyfinEmpty")
        case .empty(.channelList): Text(app: "setup.sources.channelListEmpty")
        case .empty(.portals): Text(app: "setup.clServer.askTitle")
        case .foundOn(let detail): Text(app: "setup.sources.foundOn \(detail)")
        case .fromProfile(let user, let host): Text(app: "setup.sources.fromProfile \(user) \(host)")
        case .suggested(let donor): Text(app: "setup.sources.suggested \(donor)")
        case .copied(let donor): Text(app: "setup.sources.copied \(donor)")
        case .ready: Text(app: "setup.sources.ready")
        case .detail(let detail): Text(verbatim: detail)
        case .waiting: Text(app: "setup.clServer.waiting")
        case .noNetwork: Text(app: "setup.sources.noNetwork")
        case .notForChildren: Text(app: "setup.clServer.childTitle")
        }
    }

    @ViewBuilder
    private func badge(_ badge: Look.Badge, focused: Bool) -> some View {
        switch badge {
        case .done:
            Image(systemName: Glyph.done.name)
                .font(TypeLevel.header.font)
                .foregroundStyle(focused ? ColorRole.reason.color : ColorRole.brandLight.color)
                .accessibilityLabel(Text(app: "common.done"))
        case .waiting:
            Image(systemName: Glyph.pending.name)
                .font(TypeLevel.header.font)
                .accessibilityLabel(Text(app: "setup.clServer.waiting"))
        case .unavailable:
            EmptyView()
        case .add, .found, .confirm, .takeOver:
            Text(appKey: Self.badgeKey(badge))
                .font(TypeLevel.footer.font)
                .foregroundStyle(badgeColor(badge, focused: focused))
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
                .overlay(Capsule().stroke(badgeColor(badge, focused: focused), lineWidth: 2))
        }
    }

    private func badgeColor(_ badge: Look.Badge, focused: Bool) -> Color {
        if focused { return ColorRole.reason.color }
        return badge == .found ? ColorRole.brandLight.color : ColorRole.textMatt.color
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

    // MARK: - Done

    private var footer: some View {
        HStack(spacing: 30) {
            Spacer(minLength: 0)
            if !page.canFinish {
                Text(app: "setup.sources.oneIsEnough")
                    .font(TypeLevel.lowercased.font)
                    .foregroundStyle(ColorRole.textQuiet.color)
            }
            SetupButton(title: "common.done", rank: .main, identifier: Self.doneID, focus: $focus) {
                send(.finishSources)
            }
            .opacity(page.canFinish ? 1 : 0.45)
        }
        .focusSection()
    }
}
