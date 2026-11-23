import Testing

@testable import Features

/// The catcher at the content edge (F-041, 2026-09-04): only as long as the area list
/// is on "Diagnostics".
struct SettingsContentCatcherTests {
    @Test("The catcher is in place as soon as the section names its topmost entry")
    func catcherOnlyForDiagnostics() {
        #expect(SettingsView.showsContentCatcher(focus: "section-diagnostics", firstEntry: nil))
        #expect(!SettingsView.showsContentCatcher(focus: "section-live", firstEntry: nil))
        #expect(SettingsView.showsContentCatcher(focus: "section-live", firstEntry: "visible"))
        #expect(SettingsView.showsContentCatcher(focus: "section-storage", firstEntry: "sync"))
        #expect(!SettingsView.showsContentCatcher(focus: "debugMode", firstEntry: "sync"))
        #expect(!SettingsView.showsContentCatcher(focus: nil, firstEntry: "sync"))
        #expect(SettingsView.contentCatcherID == "content-entry")
    }
}
