import Testing

@testable import Core

/// AP85: App Group and iCloud container follow the prefix from the xcconfig.
@Suite("App identifier")
struct AppIdentifierTests {

    @Test("A resolved value applies")
    func resolved() {
        #expect(AppIdentifier.from("com.example.cinelounge") == "com.example.cinelounge")
    }

    @Test("If the value is missing or the placeholder remained, the default applies")
    func preset() {
        #expect(AppIdentifier.from(nil) == AppIdentifier.preset)
        #expect(AppIdentifier.from("") == AppIdentifier.preset)
        #expect(AppIdentifier.from("$(CL_BUNDLE_PREFIX).cinelounge") == AppIdentifier.preset)
        #expect(AppIdentifier.from(42) == AppIdentifier.preset)
    }

    @Test("The derived names match the previous ones")
    func previousNames() {
        // In the test the Info.plist says nothing — the default must yield the old names.
        #expect(AppIdentifier.appGroup == "group.dev.ms-solutions.cinelounge")
        #expect(AppIdentifier.cloudContainer == "iCloud.dev.ms-solutions.cinelounge")
        #expect(AppIdentifier.sharedKeychainGroup == "dev.ms-solutions.cinelounge.shared")
    }
}
