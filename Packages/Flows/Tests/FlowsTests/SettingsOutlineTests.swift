import Foundation
import Testing
import WordingKit

@testable import Flows

/// The shared structure and search of the settings (AP58 R7, finding E5).
@Suite("Settings outline")
struct SettingsOutlineTests {

    /// The EB layout (decision 1), group by group.
    @Test("Every group carries the areas of the drawing")
    func groups() {
        func sections(_ group: SettingsGroup) -> [SettingsArea] {
            SettingsArea.allCases.filter { $0.group == group }
        }
        #expect(sections(.sources) == [.jellyfin, .channelLists, .portals, .ratings])
        #expect(sections(.watching) == [.appearance, .playback, .live, .subtitles, .language])
        #expect(sections(.device) == [.profile, .parentalControls, .devices, .storage, .diagnose, .about])
        #expect(SettingsGroup.allCases.count == 3, "Sources, Playback, Device (AP59 N7)")
    }

    @Test("Start before middle before secondary text, nothing under two characters")
    func ranks() {
        let entries = [("Tonspur", ""), ("Untertitel", ""), ("Größe", "Untertitel")]
        let match = SettingsSearch.match(
            zu: "unter", in: entries, title: \.0, secondaryText: \.1)
        #expect(match.map(\.0) == ["Untertitel", "Größe"])
        #expect(
            SettingsSearch.match(zu: "on", in: entries, title: \.0, secondaryText: \.1).map(\.0) == [
                "Tonspur"
            ])
        #expect(SettingsSearch.match(zu: "u", in: entries, title: \.0, secondaryText: \.1).isEmpty)
        #expect(SettingsSearch.fold(" Türkçe ") == SettingsSearch.fold("turkce"))
    }

    /// **The sentence at the device lock switch** (decision 23) exists once, in three
    /// languages, and names none of the devices.
    @Test("The sentence on the device lock is shared and device-neutral in three languages")
    func deviceLockWording() {
        #expect(WordingKit.hasKey("childLock.deviceLock.scope"))
        for language in ["de", "en", "tr"] {
            let message = WordingKit.text("childLock.deviceLock.scope", language: language)
            #expect(message != "childLock.deviceLock.scope", "\(language) missing")
            for word in ["Fernseher", "iPhone", "Apple TV", "TV ", "Telefon"] {
                #expect(!message.contains(word), "\(language): \(word)")
            }
        }
    }
}
