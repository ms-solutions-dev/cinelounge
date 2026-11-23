import Foundation

/// A group of recordings from the same month.
///
/// Home videos have neither curated titles nor imagery — `Video_017` says
/// nothing. What people remember is *when* something happened. So they are
/// ordered by month instead of alphabetically.
public struct DateGroup: Identifiable, Sendable, Equatable {

    /// Year and month, such as `2023-12`. As a string, so that it works as an
    /// identifier and sorts in the same order as the date.
    public let id: String
    /// The first day of the month — the basis for the heading. The view
    /// formats it in the selected language; nothing is named here.
    public let month: Date?
    public let items: [MediaItem]

    public init(id: String, month: Date?, items: [MediaItem]) {
        self.id = id
        self.month = month
        self.items = items
    }
}

extension DateGroup {

    /// Orders recordings by month, the most recent group first.
    ///
    /// Within a month it stays most recent first: whoever filmed in December
    /// usually looks for the last thing, not the first.
    ///
    /// Recordings without a date land in a group of their own **at the end**. Silently
    /// mixing them into the oldest month would be wrong — people
    /// would look for them where they do not belong.
    public static func byMonth(
        _ items: [MediaItem],
        calendar: Calendar = .current
    ) -> [DateGroup] {
        var buckets: [String: [MediaItem]] = [:]
        var months: [String: Date] = [:]
        var undated: [MediaItem] = []

        for item in items {
            guard let date = item.recordedAt else {
                undated.append(item)
                continue
            }

            let parts = calendar.dateComponents([.year, .month], from: date)
            guard let year = parts.year, let month = parts.month else {
                undated.append(item)
                continue
            }

            // Two digits for the month, otherwise `2023-9` would sort after `2023-12`.
            let key = String(format: "%04d-%02d", year, month)
            buckets[key, default: []].append(item)
            if months[key] == nil {
                months[key] = calendar.date(from: DateComponents(year: year, month: month))
            }
        }

        // Deliberately a loop and not a chain of `sorted` and `map`: the
        // compiler took disproportionately long over it and gave up.
        var result: [DateGroup] = []
        for key in buckets.keys.sorted(by: >) {
            let group = buckets[key] ?? []
            let newestFirst = group.sorted { left, right in
                let a = left.recordedAt ?? Date.distantPast
                let b = right.recordedAt ?? Date.distantPast
                return a > b
            }
            result.append(DateGroup(id: key, month: months[key], items: newestFirst))
        }

        if !undated.isEmpty {
            let none: Date? = nil
            result.append(DateGroup(id: "undated", month: none, items: undated))
        }
        return result
    }
}
