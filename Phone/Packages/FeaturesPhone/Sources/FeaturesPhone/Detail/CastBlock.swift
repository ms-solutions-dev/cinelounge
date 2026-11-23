import Core
import DesignSystemPhone
import SwiftUI

/// The cast as a scrolling row of faces.
///
/// **Only the actors appear here; director and writer appear below in the fact list.**
/// A director among twelve faces is no longer a face but an exception in a row — and
/// whoever looks for him does not look for him among the actors anyway. Both are
/// complete in the sheet.
///
/// **The row ends after twelve and says so.** A title carries up to forty names; a row
/// in which you swipe forty times is no longer a row, and the portraits for it would be
/// forty requests to a third-party endpoint.
struct CastBlock: View {

    let cast: [PersonDetail]
    /// `nil` means: no career access, the circles are not buttons.
    var openPerson: ((PersonDetail) -> Void)?
    let showAll: () -> Void

    static let inRow = 12

    var body: some View {
        let faces = cast.filter { $0.task == .cast }
        if !faces.isEmpty {
            ShelfRow(
                title: AppLanguageSetting.text("detail.cast"),
                tally: faces.count > Self.inRow
                    ? AppLanguageSetting.text("detail.castAll \(faces.count)") : nil
            ) {
                ForEach(faces.prefix(Self.inRow)) { person in
                    PersonCircle(
                        person: person,
                        open: openPerson.map { action in { action(person) } })
                }
                if faces.count > Self.inRow {
                    MoreCircle(count: faces.count - Self.inRow, action: showAll)
                }
            }
        }
    }
}

/// The thirteenth circle: "+ 28".
///
/// **A circle and not a line of text below.** It sits at the end of the same row in
/// which you are swiping — and that is the place where the question "is there more?"
/// arises at all. A line below the row only reaches whoever stops swiping.
struct MoreCircle: View {

    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle().fill(ColorRole.surface.color)
                    Circle().strokeBorder(ColorRole.outline.color, lineWidth: 0.5)
                    Text(verbatim: "+\(count)")
                        .font(TypeLevel.footer.font.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(ColorRole.text.color)
                }
                .frame(width: MetricsBoard.phone.person, height: MetricsBoard.phone.person)

                Text(appKey: "detail.castMore")
                    .font(TypeLevel.lowercased.font)
                    .foregroundStyle(ColorRole.textQuiet.color)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(width: PersonCircle.width, alignment: .top)
            .frame(maxHeight: .infinity, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
