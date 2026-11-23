import Foundation
import Testing

@testable import Grundstock

/// What is checked is what of an address reaches the log.
///
/// The log is the only place where an error on the TV can be
/// reconstructed, and it is therefore passed on. If the credentials are in it,
/// they are given away: providers block an account that comes from several places, and
/// the viewer loses not one show but TV altogether.
///
/// The addresses here are not made-up examples but the forms in which
/// IPTV providers actually hand out their addresses.
@Suite("Addresses in the log")
struct DiagnosticsRedactionTests {

    @Test("The credentials in the channel list address are not in the log")
    func m3uCredentialsAreDropped() throws {
        // The usual form of an M3U address. The user enters it as a whole line,
        // and username as well as password are in the query part.
        let url = try #require(
            URL(string: "http://panel.example:8080/get.php?username=alice&password=secret&type=m3u")
        )

        let logged = Diagnostics.loggable(url)

        #expect(!logged.contains("geheim"))
        #expect(!logged.contains("alice"))
        // And what remains must still be of some use: without host and path it would
        // no longer be possible to say which request failed.
        #expect(logged == "http://panel.example:8080/get.php")
    }

    @Test("The credentials in the program guide address are not in the log")
    func guideCredentialsAreDropped() throws {
        // The same form for the XMLTV file. It is the second address that is logged in
        // operation — and the one for which the rule was forgotten last.
        let url = try #require(
            URL(string: "http://panel.example:8080/xmltv.php?username=alice&password=secret")
        )

        #expect(Diagnostics.loggable(url) == "http://panel.example:8080/xmltv.php")
    }

    @Test("Credentials before the host name drop out as well")
    func inlineCredentialsAreDropped() throws {
        // The other common notation. It is not in the query part,
        // and whoever only removes the query part overlooks it.
        let url = try #require(URL(string: "http://alice:secret@server.example/liste.m3u"))

        let logged = Diagnostics.loggable(url)

        #expect(!logged.contains("geheim"))
        #expect(logged == "http://server.example/liste.m3u")
    }

    @Test("An address without credentials stays complete")
    func harmlessAddressSurvives() throws {
        // The control test. If it were shortened across the board, the log would lose its purpose:
        // an error when fetching `/xmltv.xml` would look like any other.
        let url = try #require(URL(string: "http://media.example:8096/epg/xmltv.xml"))

        #expect(Diagnostics.loggable(url) == "http://media.example:8096/epg/xmltv.xml")
    }

    @Test("A local file keeps its path in the log")
    func localFileKeepsItsPath() throws {
        // A file address has no host name. The user also stores their
        // XMLTV file locally, and then the path is the only usable
        // information — whoever shortened to host and port across the board here would log
        // the same empty line for every file.
        let file = try #require(URL(string: "file:///var/tmp/epg.xml"))

        #expect(Diagnostics.loggable(file) == "file:///var/tmp/epg.xml")
    }
}
