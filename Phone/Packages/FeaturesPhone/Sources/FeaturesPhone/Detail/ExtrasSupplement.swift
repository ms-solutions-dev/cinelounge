import Core
import Foundation
import ParentalControls
import PortalKit

/// The registered providers' details on a portal title's detail page (``TitleExtras``).
///
/// **The counterpart to the detail column on the TV**: on the phone there is no focus and no
/// column; the detail page is the place where you read. The people stand in the round cast row
/// that every film has; label, year, runtime and description in the fields that already exist.
/// So a portal title looks like every other — same feel, only the form factor differs.
///
/// **Only add, never overwrite:** what the list itself delivers stays. Without a registered
/// provider nothing is asked.
enum ExtrasSupplement {

    /// How long the detail page waits for the details. The first fetch of a title may go out
    /// through the CL-Server to a further service (measured 0.3–1.5 s). A page that stays empty
    /// longer would be the worse trade.
    static let deadline: Duration = .milliseconds(2500)

    static func portalDataSource(_ source: any ContentSource) -> PortalSource? {
        (source as? PortalSource) ?? ((source as? FilteredSource)?.source as? PortalSource)
    }

    /// The details of a portal title — `nil` if there are none or the deadline passes.
    static func extras(zu title: MediaItem, source: any ContentSource) async -> TitleExtras? {
        guard let portal = portalDataSource(source) else { return nil }
        return await withTaskGroup(of: TitleExtras?.self) { group in
            group.addTask { await portal.extras(forItem: title.id, title: title.title) }
            group.addTask {
                try? await Task.sleep(for: deadline)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// The title with the gaps filled: description, label, year, runtime.
    static func completed(_ title: MediaItem, um extras: TitleExtras) -> MediaItem {
        var t = title
        if (t.overview ?? "").isEmpty, !extras.description.isEmpty {
            t.overview = extras.description
        }
        if (t.studio ?? "").isEmpty, !extras.label.isEmpty {
            t.studio = extras.label
        }
        if t.year == nil, let year = Int(extras.date.prefix(4)) {
            t.year = year
        }
        if (t.runtime ?? 0) <= 0, let minutes = extras.minutes, minutes > 0 {
            t.runtime = TimeInterval(minutes * 60)
        }
        return t
    }

    /// The people as a cast row — with the picture the provider knows.
    static func cast(from extras: TitleExtras) -> [PersonDetail] {
        extras.people.map { person in
            PersonDetail(
                id: "extras-" + person.name, name: person.name, characterName: nil,
                task: .cast, image: person.image)
        }
    }
}
