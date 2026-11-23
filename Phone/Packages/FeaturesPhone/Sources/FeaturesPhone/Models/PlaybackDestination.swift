import DesignSystemPhone

/// Where playback happens: this device or the Apple TV.
///
/// **The case is called ``phone``, the label says "This device"** (AP7, 2026-09-24) —
/// that is no oversight but the separation of internal name and visible sentence. Only
/// whoever reads the source reads the name; the sentence is read by whoever is using the
/// app on an iPad in Split View right now, and "This iPhone" would simply be wrong there.
/// The counterpart ``tv`` keeps its name after its device, because it really means
/// one — that is why the contrast stays readable in the name pair.
///
/// **``icon`` still shows an iPhone here.** An image is not a sentence: The sheet puts
/// two rows next to each other, and the lower one carries a TV — a neutral box above it
/// would lose the contrast that the sheet draws. A device-appropriate icon would need the
/// size class in the model, and the size class explicitly does **not** answer the question
/// "iPhone or iPad" (Split View).
///
/// **Two cases and no device list.** This app's remote talks to exactly one second screen
/// — the Apple TV in the same household. An open list would be an AirPlay picker, and iOS
/// brings that itself; rebuilding it here would mean putting two choices for the same
/// thing next to each other.
public enum PlaybackDestination: String, Sendable, Equatable, CaseIterable, Identifiable {

    case phone = "telefon"
    case tv = "fernseher"

    public var id: String { rawValue }

    public var titleKey: String {
        switch self {
        case .phone: "common.thisDevice"
        case .tv: "target.appleTV"
        }
    }

    public var icon: String {
        switch self {
        case .phone: "iphone"
        case .tv: Glyph.target.name
        }
    }
}
