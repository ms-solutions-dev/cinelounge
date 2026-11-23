import Foundation

/// For which app version the book is kept — **and since when.**
///
/// **Without this information a report is no proof.** On 2026-09-07 the diagnostics showed
/// "266 errors", and nobody could say whether they came from this build or from
/// the day before yesterday. A report that mixes three versions looks complete and is
/// worthless: one fixes things in it that have long been fixed.
public struct LogVersion: Sendable, Equatable {

    /// Version and build number in the same notation as in ``DeviceDetails``:
    /// `1.0 (57)`. Two numbers and not one — the version rarely changes, the
    /// build number with every build, and that is exactly the one meant here.
    public let version: String

    /// When the book started for this version.
    public let started: Date

    public init(version: String, started: Date) {
        self.version = version
        self.started = started
    }

    /// How an opening line is recognized — also in a book that an older
    /// version wrote.
    static let prefix = "Log begins for version "

    /// The line with which a fresh book begins.
    ///
    /// **It stands first inside and not in the report's header.** The header says which
    /// version *produced* the report; this line says from when the entries below
    /// apply. For a book that had survived its build, that would make a difference.
    public var opening: String {
        "\(LogVersion.prefix)\(version) — \(LogVersion.clock.string(from: started))"
    }

    /// Whether this sentence is an opening and not an observation.
    ///
    /// **A book containing only the heading is empty.** Whoever does not
    /// distinguish that makes the "Put on the media server" button live right after every build
    /// — and the line below it, which says there is nothing to send,
    /// unreachable.
    public static func isOpening(_ message: String) -> Bool {
        message.hasPrefix(prefix)
    }

    /// Version and time for the value column in Settings.
    public var label: String {
        "\(version) · \(LogVersion.clock.string(from: started))"
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd.MM.yyyy HH:mm"
        f.locale = Locale(identifier: "de_DE")
        return f
    }()
}

/// When the book starts over — **on a version change and not on app launch.**
///
/// **The requirement:** the diagnostics should reset with every build, so that one can see
/// whether errors still occur or not, instead of
/// carrying old errors along. (2026-09-07)
///
/// **The difference between "with every build" and "on every launch" is the whole point.**
/// Clearing on every launch would be one line less code and the most expensive mistake this
/// package could make: if the app crashes, it restarts — and would delete
/// exactly the log of the crash. The book would then be empty in every case in which it is
/// needed, and full in every case in which it is not.
///
/// **The version is the right cut**, because it names what a finding
/// refers to: an error from build 56 says nothing about whether build 57 still has it. If the
/// version stays the same, so does the book — across crashes, restarts and days.
public enum VersionChange {

    static let versionKey = "diagnose.buch.fassung"
    static let startedKey = "diagnose.buch.begonnen"

    /// The version of this run.
    ///
    /// From the bundle and not from a maintained number in the code: what stands here must
    /// change by itself with every build, otherwise a forgotten update leads right back to
    /// the state that this is meant to eliminate.
    public static func current(from bundles: Bundle = .main) -> String {
        let details = bundles.infoDictionary
        let short = details?["CFBundleShortVersionString"] as? String ?? "?"
        let build = details?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    /// For which version the book is currently kept — `nil` as long as none is running.
    public static func state(in store: UserDefaults = .standard) -> LogVersion? {
        guard let version = store.string(forKey: versionKey),
            let started = store.object(forKey: startedKey) as? Date
        else { return nil }
        return LogVersion(version: version, started: started)
    }

    /// Whether a fresh start is needed for this version.
    ///
    /// Also on the very first run, when nothing is noted yet: then the book is empty anyway,
    /// and the opening line is the cheapest way to date it.
    static func changes(to version: String, in store: UserDefaults = .standard) -> Bool {
        state(in: store)?.version != version
    }

    /// Notes which book is running now.
    ///
    /// **In the standard store and not next to the book.** The marker must outlive the
    /// file it describes — if it lay in the same store, it would be gone after
    /// clearing, and the next launch would take that for a version change.
    static func memorize(_ state: LogVersion, in store: UserDefaults = .standard) {
        store.set(state.version, forKey: versionKey)
        store.set(state.started, forKey: startedKey)
    }
}
