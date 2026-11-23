import Core
import Foundation
import Testing

@testable import JellyfinKit

/// What of a request makes it into the trace — depending on the switch position.
///
/// The rule is extracted as a function of its own so that it can be checked here without
/// a `URLSession` with reproduced metrics. Two things hang on it: that everyday use does
/// not flood the trace, and that verbose recording really sees everything — including
/// the time to first byte of the successful fetches.
@Suite("Recording rule for requests")
struct RecordingRuleTests {

    @Test("In normal operation a successful, fast request stays out")
    func normalModeSkipsRoutineSuccess() {
        // A Home screen triggers dozens of such fetches — every single one in the trace would
        // mean losing the one error line that matters.
        #expect(
            TrustingSessionDelegate.recordingStep(failed: false, duration: 0.05, verbose: false)
                == nil
        )
    }

    @Test("In verbose mode every request is recorded")
    func verboseModeRecordsEverySuccess() {
        #expect(
            TrustingSessionDelegate.recordingStep(failed: false, duration: 0.05, verbose: true)
                == "Anfrage"
        )
    }

    @Test("Failure and slowness keep their name — in both modes")
    func anomaliesKeepTheirNames() {
        // Otherwise the finding would vanish into the uniform gray of the "request" lines as
        // soon as someone, of all things, records verbosely for troubleshooting.
        for verbose in [false, true] {
            #expect(
                TrustingSessionDelegate.recordingStep(
                    failed: true, duration: 0.05, verbose: verbose
                ) == "Connection on failure"
            )
            #expect(
                TrustingSessionDelegate.recordingStep(
                    failed: false,
                    duration: TrustingSessionDelegate.slowThreshold + 0.5,
                    verbose: verbose
                ) == "Slow request"
            )
        }
    }
}

/// The file name from the response to the log upload.
///
/// The name displayed is the one the **server** assigned — only with it can the file be
/// found again in its web interface. An invented name once appeared on the TV and
/// nowhere else.
@Suite("Log upload")
struct UploadedLogNameTests {

    @Test("Both spellings of the field name are accepted")
    func bothSpellingsAreAccepted() {
        // Jellyfin usually writes its fields in capitals; lowercase occurs too, depending on the
        // version. A field name is not a contract on which sending may fail.
        #expect(
            JellyfinSource.uploadedLogName(from: Data(#"{"fileName":"upload_a.log"}"#.utf8))
                == "upload_a.log"
        )
        #expect(
            JellyfinSource.uploadedLogName(from: Data(#"{"FileName":"upload_b.log"}"#.utf8))
                == "upload_b.log"
        )
    }

    @Test("A response without a name is one without information, not an error")
    func missingNameYieldsNothing() {
        #expect(JellyfinSource.uploadedLogName(from: Data("{}".utf8)) == nil)
        #expect(JellyfinSource.uploadedLogName(from: Data()) == nil)
        #expect(JellyfinSource.uploadedLogName(from: Data("no JSON".utf8)) == nil)
        // A name that is none — a number, say — does not count either.
        #expect(JellyfinSource.uploadedLogName(from: Data(#"{"fileName":42}"#.utf8)) == nil)
    }
}
