import Core
import Foundation
import Testing

@testable import Diagnose

@Suite("Report")
struct ReportTests {

    private var device: DeviceDetails {
        DeviceDetails(
            device: "iPhone", system: "iOS 18.2", version: "0.1.0 (7)", language: "de_DE")
    }

    /// The ID stands at the top and in the form that `DiagnosticID.fromReport`
    /// finds again — otherwise the viewer can read it aloud and nobody can match it.
    @Test("The ID is in the report and can be found again")
    func identifier() {
        let report = Report(device: device, entries: [])
        #expect(DiagnosticID.fromReport(report.text) == report.identifier)
    }

    @Test("Device and count are in there")
    func details() {
        let entries = (1...3).map {
            ContentEntryRecord(area: .network, severity: .error, message: "Error \($0)")
        }
        let text = Report(device: device, entries: entries).text
        #expect(text.contains("iOS 18.2"))
        #expect(text.contains("0.1.0 (7)"))
        #expect(text.contains("3 entries"))
        #expect(text.contains("Error 2"))
    }

    /// The entries were redacted on writing. This test records that
    /// the report does not bring anything back in.
    @Test("There is no address in the report")
    func noAddress() {
        let entry = ContentEntryRecord(
            area: .network, severity: .error,
            message: Redaction.sanitized("Abort at http://line.provider.tv/live/a/b/1.ts"))
        let text = Report(device: device, entries: [entry]).text
        #expect(!text.contains("://"))
    }

    @Test("The file is named after date and ID")
    func fileName() throws {
        let report = Report(device: device, entries: [])
        let location = try ReportOutput.file(forItem: report)
        defer { try? FileManager.default.removeItem(at: location) }
        #expect(location.lastPathComponent.contains(report.identifier))
        #expect(location.pathExtension == "log")
        #expect(try String(contentsOf: location, encoding: .utf8).contains(report.identifier))
    }
}
