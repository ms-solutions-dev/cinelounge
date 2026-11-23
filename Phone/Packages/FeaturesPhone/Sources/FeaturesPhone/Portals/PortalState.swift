import DesignSystemPhone
import Flows
import SwiftUI

extension PortalState {

    /// The symbol on the phone — never color alone.
    public var icon: String {
        switch self {
        case .ready: Glyph.done.pair.outlined
        case .login: Glyph.login.name
        case .needsSetting: Glyph.settings.name
        case .muted, .other: Glyph.offline.name
        }
    }
}

/// The state of a portal as a mark — symbol and word, only then color.
struct StateBadge: View {

    let state: PortalState

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: state.icon)
                .font(TypeLevel.lowercased.font)
            if let key = state.key {
                Text(appKey: key)
            } else if let text = state.wording {
                Text(verbatim: text)
            }
        }
        .font(TypeLevel.label.font)
        .foregroundStyle(color)
        .lineLimit(1)
    }

    private var color: Color {
        switch state {
        case .ready: ColorRole.success.color
        case .login: ColorRole.textMatt.color
        case .needsSetting: ColorRole.progress.color
        case .muted, .other: ColorRole.textQuiet.color
        }
    }
}
