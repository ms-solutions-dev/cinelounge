import Foundation

/// The report as a file that can be passed on.
///
/// On the TV the report went to the media server, because on an Apple TV one cannot get at
/// `log show`. On the phone there is the shorter way: put the file into the
/// share sheet.
public enum ReportOutput {

    /// Writes the report to a file and returns its location.
    ///
    /// In the volatile directory: a report is there to be passed on and not to be
    /// kept — what stays lying here is cleaned up by the system itself.
    ///
    /// The file name carries date and ID, as in the TV project
    /// (`2026-09-05_1204_F-023.log`): that way every report is named differently, and one sees from the
    /// name which one is meant.
    public static func file(forItem report: Report) throws -> URL {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd_HHmm"
        stamp.locale = Locale(identifier: "en_US_POSIX")

        let name = "\(stamp.string(from: report.createdAt))_\(report.identifier).log"
        let location = URL.temporaryDirectory.appending(path: name, directoryHint: .notDirectory)
        try report.text.write(to: location, atomically: true, encoding: .utf8)
        return location
    }
}
