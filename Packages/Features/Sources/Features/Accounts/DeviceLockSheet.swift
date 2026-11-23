import Core
import DesignSystem
import ParentalControls
import SwiftUI

/// **Device lock — the switch and what it does** (G3, findings C9 and C10).
///
/// **Why a sheet of its own and not two more blocks in the section:** Before G3, parental
/// controls stood at fourteen focus targets on the first level (`FocusPlanTests`, limit
/// fifteen). The two explanations the phone already carried — "What the PIN locks" and
/// the sidebar under device lock — would add thirteen more targets. They belong to the
/// switch they explain; that is why the switch, the sentence from Decision 23 and both
/// explanations sit together here, one row behind "Device lock".
struct DeviceLockSheet: View {

    @ObservedObject var lock: ParentalControlsState
    let onClose: () -> Void

    @FocusState private var focus: String?

    var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // **Without the switch** (AP59 N4, 2026-09-30): The device lock is gone —
                    // a device for children starts in the child profile. The sheet remains the
                    // explanation of what the PIN locks and what a child sees in the sidebar.
                    doors
                    bar
                }
                .frame(maxWidth: 1100, alignment: .leading)
                .padding(.horizontal, MetricsBoard.tv.margin)
                .padding(.vertical, TVMetrics.topMargin)
            }
        }
        .onAppear { focus = LockedDoors.info.first.map { "tuer-" + $0 } }
        .onExitCommand(perform: onClose)
    }

    /// **What the PIN locks** — the same doors as on the phone, read from the board
    /// (``ParentalControls/LockedDoors/info``), each with its own reason. **Every row
    /// takes focus**, otherwise the sheet would never scroll down to here on tvOS (``ValueRow``).
    private var doors: some View {
        VStack(alignment: .leading, spacing: 8) {
            ParentalControlsHeader(
                catalogTitleKey: "childLock.doors", sentenceKey: "childLock.doors.footnote")
            ForEach(LockedDoors.info, id: \.self) { door in
                ValueRow(
                    title: "childLock.door." + door, value: LockedDoors.reason(door),
                    titleWidth: 320, identifier: "tuer-" + door, focus: $focus
                )
                .frame(maxWidth: 1100, alignment: .leading)
            }
        }
        .padding(.bottom, 40)
        .focusSection()
    }

    private var bar: some View {
        VStack(alignment: .leading, spacing: 8) {
            ParentalControlsHeader(catalogTitleKey: "childLock.tabs", sentenceKey: "childLock.tabs.footnote")
            ForEach(Self.bar(), id: \.title) { entry in
                ValueRow(
                    title: entry.title,
                    value: entry.remains ? nil : AppLanguageSetting.word("childLock.tabs.gone"),
                    titleWidth: 380, identifier: "leiste-" + entry.title, focus: $focus
                )
                .frame(maxWidth: 900, alignment: .leading)
            }
        }
        .focusSection()
    }

    /// Which sidebar entries remain when the **device lock applies** — the rule
    /// is the shared one (``ParentalControls/ChildScope``), shown here only as an explanation.
    ///
    /// **Computed, not copied:** A hand-maintained list would be wrong with the next
    /// entry, and a wrong list looks like a right one. The case shown is
    /// "adult profile, device locked" — a child profile additionally cuts off
    /// Settings (Decision 20).
    nonisolated static func bar(
        _ scope: ChildScope = ProtectionRule(
            deviceLocked: true, accountKind: .adult, isPinSet: true
        ).scope
    ) -> [(title: String, remains: Bool)] {
        [
            ("tab.media", scope.isAllowed(ChildTarget.mediaLibrary)),
            ("tab.search", scope.isAllowed(ChildTarget.search)),
            ("tab.favorites", scope.isAllowed(ChildTarget.favorites)),
            ("tab.live", scope.remains("live")),
            ("tab.vod", scope.delivers("anbieter")),
            ("tab.sport", scope.showsSports),
            ("tab.portals", scope.remains("portale")),
            ("settings.title", scope.isAllowed(ChildTarget.administration)),
        ]
    }
}

/// Header and sentence of a parental-controls section — **the same form as in the section.**
struct ParentalControlsHeader: View {

    let catalogTitleKey: String
    let sentenceKey: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(appKey: catalogTitleKey)
                .font(TypeLevel.header.font)
                .foregroundStyle(ColorRole.text.color)
            Text(appKey: sentenceKey)
                .font(TypeLevel.lowercased.font)
                .foregroundStyle(ColorRole.textQuiet.color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 900, alignment: .leading)
        }
        .padding(.bottom, 6)
    }
}
