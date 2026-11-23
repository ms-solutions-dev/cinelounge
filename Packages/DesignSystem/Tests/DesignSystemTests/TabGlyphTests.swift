import Styling
import Testing

@testable import DesignSystem

/// **What the TV's views show — meaning by meaning, against the registry**
/// (AP58 final step, 2026-09-26).
///
/// Until the final step every old name (`Sinnbilder.x`) forwarded to the registry here;
/// since then the views name the meaning itself. The symbols are copied
/// on purpose: whoever changes one changes the device and is meant to decide it at this point.
/// Since the move only the rows from **decision 24** have changed (rating as a
/// half star).
@Suite("The symbols on the TV")
struct TabGlyphTests {

    static let character: [(String, String, String)] = [
        ("abruf", Glyph.fetch.name, "popcorn.fill"),
        ("abspielen", Glyph.play.name, "play.fill"),
        ("anhalten", Glyph.pause.name, "pause.fill"),
        ("anmeldung", Glyph.login.name, "person.crop.circle.badge.exclamationmark"),
        ("auffrischen", Glyph.refresh.name, "arrow.clockwise"),
        ("ausgeblendet", Glyph.hidden.name, "eye.slash"),
        ("belegt", Glyph.taken.name, "person.2.slash"),
        ("bewertung", Glyph.rating.name, "star.leadinghalf.filled"),
        ("darstellung", Glyph.appearance.name, "paintbrush"),
        ("diagnose", Glyph.diagnose.name, "stethoscope"),
        ("einreichen", Glyph.share.name, "square.and.arrow.up"),
        ("einrichtung", Glyph.setup.name, "sparkles"),
        ("einstellungen", Glyph.settings.name, "gearshape"),
        ("entfernen", Glyph.remove.name, "trash"),
        ("favorit.umrissen", Glyph.favorite.pair.outlined, "heart"),
        ("favorit.gefuellt", Glyph.favorite.pair.filled, "heart.fill"),
        ("film", Glyph.film.name, "film"),
        ("gesehen.umrissen", Glyph.done.pair.outlined, "checkmark.circle"),
        ("gesehen.gefuellt", Glyph.done.pair.filled, "checkmark.circle.fill"),
        ("gesperrt", Glyph.locked.name, "lock.fill"),
        ("haken", Glyph.override.name, "checkmark"),
        ("hinzufuegen", Glyph.add.name, "plus"),
        ("hoch", Glyph.up.name, "chevron.up"),
        ("hochladen", Glyph.upload.name, "arrow.up.circle"),
        ("kaestchen.umrissen", Glyph.checkbox.pair.outlined, "square"),
        ("kaestchen.gefuellt", Glyph.checkbox.pair.filled, "checkmark.square.fill"),
        ("kind", Glyph.kind.name, "figure.child"),
        ("kindersicherung", Glyph.parentalControls.name, "lock.shield"),
        ("klingel", Glyph.bell.name, "bell.and.waves.left.and.right.fill"),
        ("kontenVerwalten", Glyph.manageAccounts.name, "person.2.badge.gearshape"),
        ("konto", Glyph.account.name, "person.crop.circle"),
        ("leererBestand", Glyph.emptyCatalog.name, "tray"),
        ("links", Glyph.back.name, "chevron.left"),
        ("liste", Glyph.list.name, "list.bullet"),
        ("live", Glyph.live.name, "dot.radiowaves.left.and.right"),
        ("mediathek", Glyph.mediaLibrary.name, "film.stack"),
        ("nachzutragen", Glyph.toBackfill.name, "plus.circle"),
        ("netz", Glyph.network.name, "network"),
        ("ohneNetz", Glyph.offline.name, "wifi.slash"),
        ("ordner", Glyph.folder.name, "folder"),
        ("portale", Glyph.portal.name, "globe"),
        ("profilHolen", Glyph.fetchProfile.name, "iphone.and.arrow.forward"),
        ("programm", Glyph.channelList.name, "play.tv"),
        ("punkt.umrissen", Glyph.pending.name, "circle"),
        ("punkt.gefuellt", Glyph.done.pair.filled, "checkmark.circle.fill"),
        ("punktKreuz", Glyph.dotCross.name, "xmark.circle"),
        ("punktLeer", Glyph.dotEmpty.name, "circle.dotted"),
        ("rechts", Glyph.next.name, "chevron.right"),
        ("rohstrom", Glyph.rawStream.name, "waveform.badge.exclamationmark"),
        ("runter", Glyph.down.name, "chevron.down"),
        ("sammlung", Glyph.library.name, "square.grid.2x2"),
        ("sanduhr", Glyph.hourglass.name, "hourglass"),
        ("sendemast", Glyph.funk.name, "antenna.radiowaves.left.and.right"),
        ("sender", Glyph.channels.name, "tv"),
        ("sendung", Glyph.broadcast.name, "play.rectangle"),
        ("serverStumm", Glyph.serverMute.name, "server.rack"),
        ("sichtbar", Glyph.isVisible.name, "eye"),
        ("siegel", Glyph.seal.name, "checkmark.seal.fill"),
        ("speicher", Glyph.storage.name, "internaldrive"),
        ("spieltNicht", Glyph.notPlaying.name, "play.slash"),
        ("sport", Glyph.sport.name, "sportscourt"),
        ("sprache", Glyph.language.name, "character.bubble"),
        ("staffel", Glyph.season.name, "square.stack.3d.up"),
        ("start", Glyph.start.name, "house"),
        ("stoerung", Glyph.disruption.name, "exclamationmark.triangle.fill"),
        ("stoerungLeise", Glyph.warning.name, "exclamationmark.triangle"),
        ("suche", Glyph.search.name, "magnifyingglass"),
        ("tagesplan", Glyph.dayPlan.name, "calendar.day.timeline.left"),
        ("tempo", Glyph.rate.name, "speedometer"),
        ("termin", Glyph.fixture.name, "calendar"),
        ("terminFehlt", Glyph.appointmentMissing.name, "calendar.badge.exclamationmark"),
        ("ueber", Glyph.info.name, "info.circle"),
        ("uhr", Glyph.clock.name, "clock"),
        ("unbekannt", Glyph.unknown.name, "questionmark.circle"),
        ("untertitel", Glyph.subtitles.name, "captions.bubble"),
        ("verfallen", Glyph.expire.name, "clock.badge.exclamationmark"),
        ("verlauf", Glyph.history.name, "clock.arrow.circlepath"),
        ("vormerken.umrissen", Glyph.bookmark.pair.outlined, "star"),
        ("vormerken.gefuellt", Glyph.bookmark.pair.filled, "star.fill"),
        ("vorspann", Glyph.preamble.name, "forward.end.fill"),
        ("weiterschalten", Glyph.advance.name, "arrow.2.squarepath"),
        ("wiedergabe", Glyph.playback.name, "play.circle"),
        ("zertifikat", Glyph.certificate.name, "lock.trianglebadge.exclamationmark"),
        ("zurueck", Glyph.portalFetchAddress.name, "globe.badge.chevron.backward"),
        ("zuruecksetzen", Glyph.fromStart.name, "arrow.counterclockwise"),
        ("zusammenlegen", Glyph.merge.name, "arrow.triangle.merge"),
    ]

    @Test("Every meaning shows its symbol")
    func unchanged() {
        for (name, now, expected) in Self.character {
            #expect(now == expected, "\(name) shows \(now) instead of \(expected)")
        }
    }

    /// The rule of the registry applies from this side too — a falsified rule in
    /// `Styling` is thereby noticed in both platform layers.
    @Test("The register has no forbidden double assignment")
    func tabsClean() {
        #expect(Glyph.forbiddenDoubleAssignments().isEmpty)
        #expect(Glyph.favorite.name == "heart")
    }
}
