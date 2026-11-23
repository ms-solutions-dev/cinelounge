import Core
import DesignSystemPhone
import SwiftUI

/// How big a catalog is and how old.
///
/// "103 titles · List from 2026-09-02, 19:52." **Without this line an empty list cannot
/// be told from a stale one** — and with a provider whose catalog you only have as a
/// snapshot, that is the difference between "it does not carry it" and "we have not
/// checked since yesterday".
///
/// **The catalog count stands here, not on the chips.** It is cheap to get —
/// `ContentSource.itemCount` asks with `Limit: 0` and receives only the number. A
/// number on every chip would instead be a number per state, and the server does not
/// know that: `ItemFilter` has no field for watched, started or favorite.
///
/// **A missing number stays away.** `nil` means "not counted" and not "zero" —
/// for a channel list the number only comes with the full title list, and until then
/// an empty spot is more honest than a zero.
struct ProgressRow: View {

    var count: Int?
    var state: Date?
    /// Without its own side margin — when it sits next to something instead of under everything.
    var isEdgeless = false

    var body: some View {
        let split = [countText, asOfText].compactMap { $0 }
        if !split.isEmpty {
            Text(verbatim: split.joined(separator: DelimiterChars.point))
                .font(TypeLevel.lowercased.font)
                .foregroundStyle(ColorRole.textQuiet.color)
                .lineLimit(1)
                .padding(.horizontal, isEdgeless ? 0 : MetricsBoard.phone.margin)
                .frame(maxWidth: isEdgeless ? nil : .infinity, alignment: .leading)
        }
    }

    private var countText: String? {
        guard let count else { return nil }
        return AppLanguageSetting.text("common.titleCount \(count)")
    }

    private var asOfText: String? {
        guard let state else { return nil }
        return AppLanguageSetting.text(
            "library.asOf \(state.formatted(.dateTime.day().month().hour().minute()))")
    }
}
