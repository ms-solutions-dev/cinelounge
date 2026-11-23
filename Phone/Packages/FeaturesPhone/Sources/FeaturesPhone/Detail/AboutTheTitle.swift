import DesignSystemPhone
import SwiftUI

/// The fact list: the word on the left, the value on the right.
///
/// **It does not repeat the attribute line.** At the top, year, rating and two genres stand
/// in one line because they count at first glance. Here stands what was too long for that —
/// director, writer, studio, runtime and **all** genres.
///
/// **Two columns and no sentences.** "Director: Skonsta Gutrikian" as one piece would be built wrongly in
/// another language; read aligned, you find the line you
/// look for without reading the others.
struct AboutTheTitle: View {

    let details: [Detail]

    /// The width of the left column.
    ///
    /// Fixed and not measured: with a measured width the column would follow the
    /// longest word, and that is "Director" or "Production studio" depending on the title — the
    /// list would look different for two films. 92 points carry the words of the
    /// catalog; what is longer wraps instead of pushing the values.
    static let labelColumn: CGFloat = 92

    var body: some View {
        if !details.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text(appKey: "detail.about")
                    .font(TypeLevel.section.font)
                    .foregroundStyle(ColorRole.text.color)
                    .padding(.horizontal, MetricsBoard.phone.margin)
                    .padding(.bottom, 10)
                    .accessibilityAddTraits(.isHeader)

                ForEach(details) { info in
                    HStack(alignment: .firstTextBaseline, spacing: MetricsBoard.phone.gutter) {
                        Text(appKey: info.key)
                            .font(TypeLevel.label.font)
                            .foregroundStyle(ColorRole.textQuiet.color)
                            .frame(width: Self.labelColumn, alignment: .leading)
                        Text(verbatim: info.value)
                            .font(TypeLevel.label.font)
                            .foregroundStyle(ColorRole.text.color)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, MetricsBoard.phone.margin)
                    .padding(.vertical, 5)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.bottom, MetricsBoard.phone.section)
        }
    }
}
