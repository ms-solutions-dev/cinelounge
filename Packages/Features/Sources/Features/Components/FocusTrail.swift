import Core
import SwiftUI

/// The focus trail as an attachment: **observe, do not intervene.**
///
/// **Why it exists.** Focus bugs on tvOS all look the same — "the
/// cursor is somewhere else" — and the cause lies between two frames: tvOS
/// assigns focus by geometry, and the view corrects it a tiny bit
/// later. What the viewer sees of this is a flicker; what arrives in a test
/// is nothing, because the end state is correct.
///
/// Written down, however, it is unambiguous:
///
/// ```
/// [Taste]  Detailseite  ↓
/// [Fokus]  Detailseite  play → season-s2       (+12 ms)
/// [Fokus]  Detailseite  season-s2 → season-s6  (+4 ms)
/// ```
///
/// **One press, two focus lines close together is a correction.**
/// After that it can be searched — across the whole app at once, instead of at
/// the one spot where someone happened to look
/// (`scripts/focus_trace.py`).
///
/// **No behaviour.** ``focusTrail(_:_:)`` only attaches an `onChange`; it cannot
/// consume a key press and cannot shift focus. That is deliberate:
/// a tool that changes the thing it observes is useless here —
/// in this project an attached catcher has already done exactly what it was supposed
/// to measure, twice.
extension View {

    /// Records every focus change in this area.
    ///
    /// `area` names the area in which focus lives — without it the IDs of two
    /// views would sit next to each other and nobody would know which
    /// belongs where.
    func focusTrail<Value: Hashable & Sendable>(_ area: String, _ value: Value?) -> some View {
        onChange(of: value) { previous, current in
            Diagnostics.cursorMoved(
                area,
                from: previous.map(FocusTrail.name),
                to: current.map(FocusTrail.name)
            )
        }
    }
}

enum FocusTrail {

    /// What a focus ID is called in the trail.
    ///
    /// Strings appear as they are; everything else — such as
    /// ``AppSidebar/Destination`` — gets its description. Without this
    /// detour the trail would contain `Optional("play")`, and a trail that first has to
    /// be deciphered ends up unread.
    static func name(_ value: some Hashable) -> String {
        if let text = value as? String { return text }
        return String(describing: value)
    }

    /// What a directional press is called in the trail — the arrows read faster in a
    /// column than words.
    static func name(_ direction: MoveCommandDirection) -> String {
        switch direction {
        case .up: "↑"
        case .down: "↓"
        case .left: "←"
        case .right: "→"
        @unknown default: "?"
        }
    }
}
