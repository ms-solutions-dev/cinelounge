import Flows

/// Which of the shared areas (``Flows/SettingsArea``) is an area of the phone —
/// **in a file of its own**, because `scripts/catalog.py` reads every `case .a: .b` in
/// `SettingsModel.swift` as a jump target.
extension SettingsModel.Area {

    /// Which of the shared areas this one is — the group follows from it.
    public var area: SettingsArea {
        switch self {
        case .account: .jellyfin
        case .channelLists: .channelLists
        case .portals: .portals
        case .ratings: .ratings
        case .appearance: .appearance
        case .playback: .playback
        case .live: .live
        case .parentalControls: .parentalControls
        case .devices: .devices
        case .storage: .storage
        case .diagnose: .diagnose
        case .about: .about
        }
    }
}
