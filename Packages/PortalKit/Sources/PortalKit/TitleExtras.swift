import Foundation

/// Additional details on a portal title — an image, the people involved with their picture, a
/// label line with date and length, and a description.
///
/// **Delivered by an extension, never by the core.** The core only knows where the details are
/// shown (the detail column on the TV, the detail page on the phone) and when they are asked for
/// (after a dwell time, see `ExtrasLookup` in Features). Who answers is registered as a
/// ``TitleExtrasProvider`` in ``AppExtensions``; without one, nothing is asked and nothing changes.
///
/// What arrives here is meant to be shown as it is: a provider only answers with details it is
/// sure belong to the title.
public struct TitleExtras: Sendable, Equatable {

    /// A person involved in the title, with a picture where there is one.
    public struct Person: Sendable, Equatable, Identifiable {
        public let name: String
        public let image: URL?

        public var id: String { name }

        public init(name: String, image: URL?) {
            self.name = name
            self.image = image
        }
    }

    /// The line that names who made or published the title — shown as a pill.
    public let label: String
    /// `2026-10-11`, as ISO date; empty if unknown.
    public let date: String
    public let minutes: Int?
    public let people: [Person]
    public let description: String
    public let image: URL?

    public init(
        label: String, date: String = "", minutes: Int? = nil,
        people: [Person] = [], description: String = "", image: URL? = nil
    ) {
        self.label = label
        self.date = date
        self.minutes = minutes
        self.people = people
        self.description = description
        self.image = image
    }

    /// `2026-10-11` → `11.10.2026`; what cannot be read stays as it came.
    public var readableDate: String {
        let split = date.split(separator: "-")
        guard split.count == 3 else { return date }
        return "\(split[2]).\(split[1]).\(split[0])"
    }
}

/// Supplies ``TitleExtras`` for a portal title — a documented extension point.
///
/// Registered with ``AppExtensions/add(extrasProvider:)``. The providers are asked in the order
/// they were registered; the first answer that is not `nil` wins. A provider that has nothing to
/// say answers `nil` — and every error is such a "nothing".
public protocol TitleExtrasProvider: Sendable {

    /// The details for one title, or `nil`.
    ///
    /// - Parameters:
    ///   - portal: The portal identifier the title belongs to.
    ///   - itemID: The full item identifier.
    ///   - title: The title as the list shows it.
    ///   - source: The portal connection — for ``PortalSource/portalRequest(_:_:_:)``.
    func extras(
        portal: String, itemID: String, title: String, source: PortalSource
    ) async
        -> TitleExtras?
}

extension PortalSource {

    /// The registered providers' details on a portal title — or `nil` if none has any.
    ///
    /// Called **after the dwell time**, for the one title in focus (see `ExtrasLookup` in
    /// Features). Without a registered provider this returns at once and sends no request.
    public func extras(
        forItem itemID: String, title: String, from extensions: AppExtensions = .shared
    ) async -> TitleExtras? {
        guard let identifier = PortalItemID(itemID), !title.isEmpty else { return nil }
        for provider in extensions.extrasProviders {
            if let found = await provider.extras(
                portal: identifier.portal, itemID: itemID, title: title, source: self)
            {
                return found
            }
        }
        return nil
    }
}
