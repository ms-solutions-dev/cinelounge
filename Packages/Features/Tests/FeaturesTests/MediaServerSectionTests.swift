import Testing

@testable import Features

/// **"Media server" instead of "Account", under Sources instead of under About** — product decision 5
/// of 2026-09-24, after the drawing `EB`.
@Suite("The Jellyfin section")
struct MediaServerSectionTests {

    /// It answers *where does something come from*, like the channel lists — and stands first
    /// there, because without it no media library shows anything.
    @Test("Jellyfin comes first under Sources")
    func underSourcesFirst() {
        #expect(SettingsSection.account.group == .sources)
        #expect(SettingsSection.allCases.first == .account)
    }

    /// **The raw value stays**, otherwise everyone who was last here lands somewhere else the next
    /// time they open it — the remembered area is stored under exactly this word.
    @Test("The stored raw value is unchanged")
    func rawValueStays() {
        #expect(SettingsSection.account.rawValue == "account")
    }

    /// "About" has been, since AP59 N7, no longer a group of its own but the last area under Device.
    @Test("About comes last under Device")
    func aboutAppOnly() {
        #expect(SettingsSection.about.group == .device)
        #expect(SettingsSection.allCases.last == .about)
    }

    /// **The assignment is shared** (AP58 R7): Live answers *what of it can be watched*
    /// and stands under Watch — on the phone it had stood under Sources until then.
    @Test("Live is under Watch, as on the phone")
    func liveUnderWatch() {
        #expect(SettingsSection.live.group == .watching)
    }
}
