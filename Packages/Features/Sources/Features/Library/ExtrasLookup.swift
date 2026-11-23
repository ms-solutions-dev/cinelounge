import Core
import Foundation
import PortalKit

/// Fetches the title details of a registered provider for the title in focus — only once it
/// stays put (see ``TitleExtras``).
///
/// **The same rule as for the trailer** (``TrailerAutostart``): while browsing, no
/// request goes out; the request is made for the title someone is looking at. The dwell time
/// is, however, **shorter and independent of the trailer switch** — the details are reading material without sound,
/// and a column that only fills after three seconds looks like an empty one.
///
/// **What came once stays for the session**, even a "nothing": whoever moves back and forth
/// between two titles should not see the column expand and collapse twice.
@MainActor
final class ExtrasLookup: ObservableObject {

    /// The details together with the identifier of the title they belong to — as with
    /// ``TrailerAutostart/Running``, so that after a focus change the details of the
    /// previous title do not sit next to the new image.
    struct Hit: Equatable {
        let itemID: String
        let details: TitleExtras
    }

    @Published private(set) var fund: Hit?

    /// Short enough that the column is filled before the eye reads it; long enough that
    /// moving on at the pace of the remote (measured around 0.3 s) triggers nothing.
    static let dwellTime: TimeInterval = 0.6

    private var remembered: [String: TitleExtras?] = [:]
    private var load: @MainActor (MediaItem) async -> TitleExtras?
    private let wait: @MainActor (TimeInterval) async -> Void
    private(set) var pending: Task<Void, Never>?

    init(
        load: @escaping @MainActor (MediaItem) async -> TitleExtras? = { _ in nil },
        wait: @escaping @MainActor (TimeInterval) async -> Void = TrailerAutostart.sleep
    ) {
        self.load = load
        self.wait = wait
    }

    func configure(load: @escaping @MainActor (MediaItem) async -> TitleExtras?) {
        self.load = load
    }

    /// A different title is in focus.
    func focus(_ item: MediaItem?) {
        pending?.cancel()
        pending = nil
        guard let item else {
            fund = nil
            return
        }
        if let existing = remembered[item.id] {
            fund = existing.map { Hit(itemID: item.id, details: $0) }
            return
        }
        fund = nil
        pending = Task { [weak self] in
            guard let self else { return }
            await self.wait(Self.dwellTime)
            guard !Task.isCancelled else { return }
            let details = await self.load(item)
            guard !Task.isCancelled else { return }
            self.remembered[item.id] = .some(details)
            self.fund = details.map { Hit(itemID: item.id, details: $0) }
        }
    }

    func stop() {
        pending?.cancel()
        pending = nil
    }
}
