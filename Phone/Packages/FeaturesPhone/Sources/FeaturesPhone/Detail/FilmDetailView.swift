import SwiftUI

/// A film: no seasons, but chapters and the series of parts.
///
/// **Not a separate screen but an entry point with a different name.** On the TV
/// film and series are two views, because two focus paths had to be built there; here
/// the difference is one line in the content — ``DetailContent/isSeries`` decides whether the
/// episode list appears. Two views for that would be two places where the same ten
/// blocks would have to be maintained, and the second would inevitably lag behind.
///
/// **This name exists anyway**, because the router knows it (``ViewID``)
/// and because it appears in the design: whoever looks for "the film page" should find it.
public typealias FilmDetailView = DetailView
