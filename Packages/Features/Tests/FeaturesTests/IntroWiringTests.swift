import Foundation
import SourceProbe
import Testing

/// **The stage draws by date and passes the ringtone on** (AP51, 2026-09-25).
///
/// ``IntroStage`` is `#if os(tvOS)` and is never compiled by `swift test`; the calculation
/// is tested in `Core` (`IntroSeasonTests`). All that is stated here is that the stage uses
/// it — otherwise the season would remain a tested function without a caller.
@Test("Intro stage: quote of the day and ringtone are connected")
func introStageWired() throws {
    let text = try SourceText.read("IntroStage.swift", in: .features)
    #expect(text.contains("catalog.select(\n                on: now"))
    // Season and still-frame deadline by the Gregorian day (counter-check strand D).
    #expect(text.contains("let dayCalendar = IntroCatalog.deviceCalendar"))
    #expect(!text.contains("kalender: .current,\n                vorhanden"))
    #expect(text.contains("forItem: clip, on: now, calendar: dayCalendar"))
    #expect(!text.contains("catalog.select(using:"))
    #expect(text.contains("audio: appearance.audioURL"))
    #expect(text.contains("controller.bell?.play()"))
}
