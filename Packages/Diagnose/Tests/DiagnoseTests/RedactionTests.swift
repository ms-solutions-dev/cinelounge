import Foundation
import Testing

@testable import Diagnose

/// The one test that really counts.
///
/// **The texts have the real form, but invented values.** A test file with a
/// real provider credential would be exactly the leak that the rule is meant to prevent — it would then lie
/// in the history forever. The form is what matters: at this
/// provider, user name and password stand **in the path**, not in a header, and exactly
/// there none of the then-current protection rules in the TV project looked.
@Suite("Redaction")
struct RedactionTests {

    @Test("Wherever an address occurs, the whole text does not go out")
    func addressInPath() {
        let realForm = "Abort at http://line.provider.tv:8080/live/jdoe/secret123/4711.ts"
        let clean = Redaction.sanitized(realForm)
        #expect(!clean.contains("secret123"))
        #expect(!clean.contains("jdoe"))
        #expect(!clean.contains("://"))
    }

    @Test("Also in the middle of a foreign error text")
    func addressInMiddle() {
        let foreign = """
            The operation couldn’t be completed. (NSURLErrorDomain error -1001.) \
            URL: https://vault.example:8096/Items/abc/Download?api_key=xyz
            """
        #expect(!Redaction.sanitized(foreign).contains("api_key"))
    }

    @Test("A file path no longer reveals which title it was")
    func pathWithoutTitle() {
        let path = "/var/mobile/Downloads/Kobe Runaways S01E04.mp4 could not be read"
        let clean = Redaction.withoutPaths(path)
        #expect(!clean.contains("Tokyo"))
        // The extension stays: it says that it was a video, and not which.
        #expect(clean.contains("(path).mp4"))
        #expect(clean.contains("could not be read"))
    }

    @Test("A harmless sentence stays as it is")
    func harmless() {
        let message = "Channel list refreshed, 2055 channels in 214 ms"
        #expect(Redaction.sanitized(message) == message)
    }

    @Test("Line breaks are smoothed so the report does not fall apart")
    func lineBreaks() {
        #expect(!Redaction.sanitized("first line\nsecond line").contains("\n"))
    }
}
