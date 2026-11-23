import Foundation

/// The address of a broadcast that has already aired.
///
/// **51 of 5389 channels of the test provider offer three days of archive**
/// (`design/konzept-p8.md`, section 4); that a channel can do it is stated as `tv_archive`
/// in its entry and has been in ``Channel/archiveDays`` since E6.
///
/// **Why the address is built from the running one and not from the access.** The path
/// through ``XtreamEndpoint`` presupposes that the view knows the access — but the channel
/// list knows only its channels, and a channel carries its address with it. Both paths end
/// here so the format lives in **one** place: Where two build sites write the same pattern,
/// sooner or later one of them writes it differently.
public enum Catchup {

    /// `YYYY-MM-DD:HH-MM` — the provider format for the start.
    ///
    /// **The colon between day and hour is not a typo**, and that is why no `ISO8601`
    /// formatting is used here: No common pattern writes it like that. Whoever takes one gets
    /// an address that the server accepts and answers with the wrong hour.
    ///
    /// **In the provider's time zone, not the device's.** The server computes against its own
    /// clock; with an hour of difference the broadcast before it comes — without any error
    /// message.
    public static func stamp(_ date: Date, in timeZone: TimeZone = .gmt) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let split = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        func two(_ value: Int?) -> String { String(format: "%02d", value ?? 0) }
        return "\(split.year ?? 0)-\(two(split.month))-\(two(split.day))"
            + ":\(two(split.hour))-\(two(split.minute))"
    }

    /// Builds the catch-up address from the address of the running channel.
    ///
    /// `…/live/USER/PASSWORD/ID.ts` becomes
    /// `…/timeshift/USER/PASSWORD/DURATION/START/ID.m3u8`.
    ///
    /// - Returns: `nil` if the address is not built that way (a channel from a plain M3U list,
    ///   for example) or the duration is not one. Neither is a fault, it means: **there is no
    ///   catch-up here** — and the view may know that before it offers it.
    public static func address(fromLive live: URL, start: Date, minutes: Int) -> URL? {
        guard minutes > 0 else { return nil }

        // It is split at the path and not with a pattern: User name and password may contain
        // anything, including dots and hyphens.
        var split = live.pathComponents.filter { $0 != "/" }
        guard split.count >= 4, split[0] == "live" else { return nil }
        let identifier = (split.removeLast() as NSString).deletingPathExtension
        // **Not just "not empty".** With `…/live/u/p/.ts` the last component is a dot name; to the
        // system it has no extension at all, and `deletingPathExtension` returns it unchanged. The
        // result was the address `…/.ts.m3u8` — one the server can only reject.
        guard !identifier.isEmpty, !identifier.hasPrefix(".") else { return nil }
        let user = split[1]
        let password = split[2]

        guard var basis = URLComponents(url: live, resolvingAgainstBaseURL: false) else {
            return nil
        }
        // Assembled by hand: A slash in the password would become `%2F` via `URLComponents`, and
        // the server would not find the path.
        basis.path = ""
        basis.query = nil
        guard let stem = basis.string else { return nil }
        return URL(
            string: stem
                + "/timeshift/\(user)/\(password)/\(minutes)/"
                + "\(stamp(start))/\(identifier).m3u8")
    }

    /// Whether a channel offers catch-up at all — and whether the requested time still lies in
    /// its archive.
    ///
    /// **The provider promises more than it keeps** (concept, section 4: "the rule, not the
    /// exception"). This check catches only the case that is already recognisable from the
    /// number; the rest has to fail honestly.
    public static func isInArchive(_ channel: Channel, start: Date, now: Date) -> Bool {
        guard let days = channel.archiveDays, days > 0 else { return false }
        guard start < now else { return false }
        return now.timeIntervalSince(start) <= Double(days) * 24 * 3600
    }
}
