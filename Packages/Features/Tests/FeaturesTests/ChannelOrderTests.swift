import SwiftUI
import Testing

@testable import Features

/// **The order of the chosen channels can be changed** (AP46 and AP32, from E80;
/// built on 2026-09-25).
///
/// The calculation lives in `Core` (`ChannelOrderingTests`). What stands here is what attaches it
/// to the screen: **The picker must pass it on.** ``ColumnChoice`` draws the
/// arrows only if someone gives it `arrange` — and a picker that forgets it looks
/// exactly like before, only without arrows. That is the bug that nobody
/// notices on screen, because nothing looks broken.
@Suite("Channel shelf · order on screen")
@MainActor
struct ChannelOrderTests {

    @Test("The channel picker passes the reordering on to the columns")
    func channelChoicePassesOrderOn() throws {
        let texts = try FocusPlan.sourceTexts()
        let bodyContent = try #require(FocusPlan.bodyContent("ChannelShelfChoice", in: texts))
        #expect(
            bodyContent.contains("arrange: {"),
            "SenderregalWahl does not pass `ordne` on to Spaltenwahl — no arrows")
        #expect(bodyContent.contains("moveChannel("), "SenderregalWahl does not move in the store")
    }

    /// **The arrows take space from the row, not from the column.** Otherwise the right
    /// column would run out to the right by two buttons — on a TV that is not
    /// scrollable but gone.
    ///
    /// **And both columns fit into the row column** (on-device test 2026-09-27, T12): until
    /// then this test checked the 760 of the right column, but never that on the left 480 and
    /// the gap beside it still had room — together 1346 points in a column of 900.
    @Test("With arrows the column stays wide enough, and both fit side by side")
    func columnKeepsItsWidth() {
        typealias Choice = ColumnChoice<EmptyView>
        #expect(Choice.selectedWidth(orders: true) + 2 * Choice.buttonSpace == Choice.folderWidth)
        #expect(Choice.selectedWidth(orders: false) == Choice.folderWidth)
        #expect(
            Choice.sourceWidth + Choice.columnSpacing + Choice.folderWidth <= SettingsView.contentWidth)
    }
}
