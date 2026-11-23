import Core
import Foundation
import SQLite3

/// Channels and program on disk — the stock of the Live area.
///
/// **Why a database and not an in-memory dictionary** (roadmap P8.1):
/// One access carries 5389 channels, and the full program guide of the
/// tested provider is 75 MiB. Keeping both in working memory
/// is out of the question on a device that shares it with the running picture.
/// And fetching both anew at every start is the most common complaint about the
/// competition: "loads for minutes on every open".
///
/// Here the catalog lies on disk and survives a restart. The view
/// asks in milliseconds what it shows; the network is only bothered when
/// syncing.
///
/// **Why hand-written SQLite and no third-party package:** The app deliberately has only
/// VLCKit as a third-party dependency. For two tables and five queries a second import
/// is not worth it; `libsqlite3` is available on every Apple device.
///
/// **Why an actor:** Writing happens during the sync, reading while
/// drawing. SQLite does not tolerate both at once on the same
/// connection — the actor queues them.
public actor LiveCache {

    public static let shared = LiveCache()

    private var handle: OpaquePointer?
    private let fileURL: URL

    /// How many days of program are kept.
    ///
    /// Three days ahead is what the providers deliver; **two days
    /// back**: one for the catch-up channels (roadmap P8), the second
    /// for the first-wins rule of the schedule — the Friday match still runs
    /// on Sunday as a recording, and only whoever still sees the original broadcast
    /// recognizes the rerun (2026-08-16).
    static let keepForward: TimeInterval = 3 * 24 * 3600
    static let keepBackward: TimeInterval = 48 * 3600

    /// **Caches, not Application Support** (on-device finding 2026-08-16: "Schedule
    /// stays empty despite 60,954 programs"): tvOS permits persistent writing
    /// only under Caches — in Application Support `sqlite3_open` failed
    /// silently on the device, every store operation was swallowed, and on the Mac
    /// the same code was green, because both are writable there. The stock
    /// is a cache anyway: If the system clears it, the sync fetches it again.
    /// Trace and snapshots live there for the same reason.
    public init(directory: URL? = nil) {
        let base =
            directory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("cinelounge-live.sqlite")
    }

    // MARK: - Aufbau

    /// Opens the database and creates the tables.
    ///
    /// The version number lives in `user_version` — the way SQLite provides
    /// for this. **Migrations from day one**, because data loss on
    /// update is the deadliest competitor complaint (market research): Whoever
    /// introduces the number only when needed can no longer recognize the first
    /// version.
    private func open() throws {
        guard handle == nil else { return }

        var db: OpaquePointer?
        guard sqlite3_open(fileURL.path, &db) == SQLITE_OK, let db else {
            sqlite3_close(db)
            // Always into the trace, never silent: Exactly this failure stayed invisible
            // on the device for weeks, because every call site
            // swallows with `try? open()` — the stock looked filled and was empty.
            Diagnostics.playbackProblem(
                "Cache database cannot be opened: \(fileURL.path)", since: nil)
            throw Failure.cannotOpen
        }
        handle = db

        // Writing and reading must not lock each other out; without
        // WAL a running sync blocks every query of the view.
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA synchronous=NORMAL;")

        let version = value(of: "PRAGMA user_version;")
        if version < 1 {
            exec(
                """
                CREATE TABLE IF NOT EXISTS channels (
                    id TEXT PRIMARY KEY,
                    playlist TEXT NOT NULL,
                    name TEXT NOT NULL,
                    grp TEXT,
                    logo TEXT,
                    epg TEXT,
                    stream TEXT NOT NULL,
                    adult INTEGER NOT NULL DEFAULT 0,
                    archive INTEGER,
                    position INTEGER NOT NULL
                );
                """
            )
            exec("CREATE INDEX IF NOT EXISTS channels_playlist ON channels(playlist, position);")
            exec(
                """
                CREATE TABLE IF NOT EXISTS programmes (
                    id TEXT PRIMARY KEY,
                    epg TEXT NOT NULL,
                    title TEXT NOT NULL,
                    detail TEXT,
                    start INTEGER NOT NULL,
                    stop INTEGER NOT NULL
                );
                """
            )
            // The index that every query of the view rests on: "what is on
            // this channel at this time". Without it every question reads the whole
            // table — for a hundred thousand entries that takes seconds.
            exec("CREATE INDEX IF NOT EXISTS programmes_epg_start ON programmes(epg, start);")
            exec("PRAGMA user_version=1;")
        }

        // **Version 2 as its own step.** The table was added a day after
        // the first version; anyone who already had a database would otherwise run
        // into the fallback "unknown means old" and fetch the channels on every
        // open — exactly what the timestamp is meant to prevent. Migration
        // means: The step runs for every older version, not only on the
        // first creation.
        if version < 2 {
            exec("CREATE TABLE IF NOT EXISTS meta (id INTEGER PRIMARY KEY, saved INTEGER);")
            exec("PRAGMA user_version=2;")
        }

        // **Version 3: a board for notes about the stock itself** (E1 of the
        // sports concept). The `meta` table above it carries exactly one number and
        // has no room for this; extending it would mean attaching a column to a
        // table that came into being outside the version check —
        // the trap that the concept explicitly names.
        //
        // It is needed for the time of the last guide fetch. Without
        // it, the device cannot tell whether the schedule is empty
        // because nothing is on, or because the guide has not been fetched for days
        // — and `syncGuide()` had exactly ONE trigger in the whole
        // project.
        if version < 3 {
            exec("CREATE TABLE IF NOT EXISTS notiz (schluessel TEXT PRIMARY KEY, wert TEXT);")
            exec("PRAGMA user_version=3;")
        }

        // **Version 4: the fixtures carry their origin** (E6).
        //
        // Until here the `fixtures` board came into being OUTSIDE the
        // version check, with `CREATE TABLE IF NOT EXISTS`. The concept
        // (section 3) warns against exactly that, and the trap is vicious: Appending columns
        // there stays ineffective on every existing database, the
        // extended INSERT then fails silently, and ``save(fixtures:of:)``
        // bails out — on every device that already had the app, the fixtures would
        // vanish silently while the Mac stayed green.
        //
        // That is why it is dropped and recreated, and why this stands
        // here in a stage of its own. Dropping costs nothing: Fixtures are
        // a cache that the next sync refills in one go.
        //
        // Three columns are added. `source` and the prefixed IDs
        // separate the two sources — without them one would silently overwrite
        // the other's row. `slug` carries the competition ID
        // from the one board, so that the placeholder is looked up and not
        // guessed by name similarity. `home_alt`/`away_alt` hold
        // the spellings that the source delivers along with it.
        if version < 4 {
            exec("DROP TABLE IF EXISTS fixtures;")
            exec(
                """
                CREATE TABLE fixtures (
                    id TEXT PRIMARY KEY,
                    source TEXT NOT NULL,
                    slug TEXT NOT NULL,
                    sport TEXT NOT NULL,
                    league TEXT NOT NULL,
                    home TEXT NOT NULL,
                    away TEXT NOT NULL,
                    home_alt TEXT,
                    away_alt TEXT,
                    start INTEGER NOT NULL
                );
                """
            )
            // The query is always for a time window, never for an
            // ID — the index therefore sits on `start`.
            exec("CREATE INDEX IF NOT EXISTS fixtures_start ON fixtures(start);")
            exec("PRAGMA user_version=4;")
        }

        // **Version 5: the living channel board** (E7).
        //
        // It is the answer to a product objection of 2026-08-29: Committing today to
        // "Bundesliga runs on these channels" does not have to remain a fact in
        // three years — rights can be reassigned. Instead of maintaining rights, the app records what it has
        // **observed** in the viewer's guide: If
        // "Bergland München – Union Kesselburg" appeared in the EPG of "DE: ARENA BUNDESLIGA 1
        // HD", then this channel carried the Bundesliga. The rules
        // for that — what may write, from how many days on it is read, and
        // when a row dies — live in ``SportChannelBoard``; here there is
        // only the store.
        //
        // **A stage of its own and no column on something existing.** That is
        // the house rule from E1, and it has a reason: `fixtures` came into being
        // until version 4 with `CREATE TABLE IF NOT EXISTS` outside the
        // version check, and appending columns there stayed ineffective on every
        // existing database.
        //
        // `league_short` is added to `fixtures` in the same stage — with
        // `ALTER TABLE`, which is allowed here because the board has been inside the
        // check since version 4 and every database passes through this stage exactly
        // once. It is the short form with which the source names the
        // competition ("Bundesliga", "EFL Championship"); without it
        // the channel board would have no vocabulary except a hand-kept list.
        if version < 5 {
            exec("ALTER TABLE fixtures ADD COLUMN league_short TEXT;")
            exec(
                """
                CREATE TABLE sender_wettbewerb (
                    sender TEXT NOT NULL,
                    pfad TEXT NOT NULL,
                    herkunft TEXT NOT NULL,
                    treffer INTEGER NOT NULL,
                    zuerst INTEGER NOT NULL,
                    zuletzt INTEGER NOT NULL,
                    PRIMARY KEY (sender, pfad)
                );
                """
            )
            // The query is for a channel; aging goes by `recent`.
            exec(
                "CREATE INDEX IF NOT EXISTS sender_wettbewerb_zuletzt "
                    + "ON sender_wettbewerb(zuletzt);")
            exec("PRAGMA user_version=5;")
        }

        // **Version 6: the program ID carries the title** (on-device finding
        // 2026-08-29, 18:06).
        //
        // Until here a program was determined by channel and start time,
        // on the grounds that two programs could not begin at the same time on one
        // channel. The tested provider does exactly that: In the
        // guide of 2026-08-29, 898 of 30,157 rows were dropped at this ID,
        // and only 94 of them were real duplicates. The viewer therefore saw
        // matches in the schedule that were not running on the channel,
        // while the running one was missing.
        //
        // **Migrated instead of dropped.** Deleting the guide would have
        // been the shorter way, but would have put every viewer in front of an empty sports area after
        // the update until they refresh by hand — it is fetched only on demand. Because the ID carries the
        // title in plain text, the store can migrate it itself: The
        // title is in the same row.
        //
        // Nothing can collide in the process. The old IDs were unique,
        // and appending something at the end cannot make two different ones equal.
        // The rows that the parser used to discard do not
        // come back this way — they are in no database; they come with
        // the next guide.
        if version < 6 {
            exec("UPDATE programmes SET id = id || '#' || title;")
            exec("PRAGMA user_version=6;")
        }

        // **Version 7: the computed schedule survives the restart**
        // (on-device finding 2026-08-29: everything is reloaded on every app open,
        // although that should only happen once a day —
        // the program run does not change over the course of the day)
        //
        // The result store from E5 lived exclusively in working memory.
        // It saved the second tab switch but not the second start —
        // and the app is opened more often than the tab is switched. At
        // device size one pass costs 3.4 s.
        //
        // The key is the same as in working memory
        // (``ScheduleCalculator/Key``): window, count and reach of
        // the stock, switch of the sync. If none of that changes, the
        // answer cannot be a different one — and that is exactly the promise the
        // viewer has in mind.
        if version < 7 {
            exec(
                """
                CREATE TABLE spielplan (
                    schluessel TEXT PRIMARY KEY,
                    ereignisse TEXT NOT NULL,
                    angelegt INTEGER NOT NULL
                );
                """
            )
            exec("PRAGMA user_version=7;")
        }

        // **Version 8: the broadcast plan** (user draft 2026-08-29). Which
        // match runs on which channel — from a source that answers exactly
        // this question, instead of from the provider's guide,
        // which demonstrably cannot answer it. Rationale at
        // ``Core/SportBroadcastPlan``.
        //
        // It is stored because the schedule is computed at any time
        // and not only right after the fetch. It is fetched together with
        // the fixtures, once per refresh.
        if version < 8 {
            exec(
                """
                CREATE TABLE sendeplatz (
                    spiel TEXT NOT NULL,
                    anstoss INTEGER NOT NULL,
                    heim TEXT,
                    gast TEXT,
                    sender TEXT NOT NULL,
                    PRIMARY KEY (spiel, anstoss)
                );
                """
            )
            exec("PRAGMA user_version=8;")
        }

        // **Version 9: the broadcast slot carries its end** (on-device finding 2026-08-29,
        // 21:00: a Mill U vs Ashwick match was displayed at 17:30 although
        // the broadcast was at 21:00). The source names start **and** end; version 8 stored only
        // the start and therefore guessed the row at two hours.
        //
        // Dropped and recreated: The broadcast plan is a cache that the
        // next sync refills in one go.
        if version < 9 {
            exec("DROP TABLE IF EXISTS sendeplatz;")
            exec(
                """
                CREATE TABLE sendeplatz (
                    spiel TEXT NOT NULL,
                    anstoss INTEGER NOT NULL,
                    ende INTEGER,
                    heim TEXT,
                    gast TEXT,
                    sender TEXT NOT NULL,
                    land TEXT,
                    PRIMARY KEY (spiel, anstoss)
                );
                """
            )
            exec("PRAGMA user_version=9;")
        }

        // **Version 10: the broadcast slot carries sport and competition.** The
        // source names both in the state of the page; until 2026-08-29, 22:00 the
        // parser read only its `schema.org` data, and that does not name them.
        // On the TV, volleyball therefore appeared under football.
        if version < 10 {
            exec("ALTER TABLE sendeplatz ADD COLUMN sportart TEXT;")
            exec("ALTER TABLE sendeplatz ADD COLUMN wettbewerb TEXT;")
            exec("PRAGMA user_version=10;")
        }
    }

    // MARK: - Der Sendeplan

    public func broadcastSlots() -> [SportBroadcastPlan.BroadcastSlot] {
        guard (try? open()) != nil, let db = handle else { return [] }
        var statement: OpaquePointer?
        let sql =
            "SELECT spiel, anstoss, ende, heim, gast, sender, land, sportart, wettbewerb "
            + "FROM sendeplatz "
            + "ORDER BY anstoss;"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        var found: [SportBroadcastPlan.BroadcastSlot] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let match = text(statement, 0), let channels = text(statement, 5) else { continue }
            found.append(
                SportBroadcastPlan.BroadcastSlot(
                    match: match,
                    home: text(statement, 3),
                    away: text(statement, 4),
                    kickoff: Date(
                        timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 1))),
                    channels: channels.components(separatedBy: "\u{1F}"),
                    end: sqlite3_column_type(statement, 2) == SQLITE_NULL
                        ? nil
                        : Date(
                            timeIntervalSince1970: TimeInterval(
                                sqlite3_column_int64(statement, 2))),
                    sportKind: text(statement, 7),
                    competition: text(statement, 8),
                    land: text(statement, 6)))
        }
        return found
    }

    /// Stores the broadcast plan — **all of it, or not at all**.
    ///
    /// An empty plan is not written: The source is a web page,
    /// and "today it does not answer" must not have the same effect as "today
    /// nobody is broadcasting". Yesterday's plan, on the other hand, ages by itself — it
    /// carries its kickoff times with it, and the sync searches in a
    /// quarter-hour around kickoff.
    public func setBroadcastSlots(_ slots: [SportBroadcastPlan.BroadcastSlot]) {
        guard !slots.isEmpty, (try? open()) != nil, let db = handle else { return }
        exec("BEGIN TRANSACTION;")
        exec("DELETE FROM sendeplatz;")
        var statement: OpaquePointer?
        // **Columns spelled out, not `VALUES (?, ?, …)`.** When converting
        // to version 9, `end` was added as the third column, and the bindings
        // stayed where they were: The home name landed in `end`, `away`
        // stayed empty, and on reading the text became the number 0 — every row
        // from the broadcast plan ended in 1970 and dropped out of the daily list. On the
        // device it looked as if the area did not update.
        //
        // With spelled-out columns this mix-up can no longer
        // happen: A new column in the middle shifts nothing.
        let sql =
            "INSERT OR REPLACE INTO sendeplatz "
            + "(spiel, anstoss, ende, heim, gast, sender, land, sportart, wettbewerb) "
            + "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);"
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            for slot in slots {
                sqlite3_reset(statement)
                bind(statement, 1, slot.match)
                sqlite3_bind_int64(statement, 2, Int64(slot.kickoff.timeIntervalSince1970))
                if let end = slot.end {
                    sqlite3_bind_int64(statement, 3, Int64(end.timeIntervalSince1970))
                } else {
                    sqlite3_bind_null(statement, 3)
                }
                if let home = slot.home {
                    bind(statement, 4, home)
                } else {
                    sqlite3_bind_null(statement, 4)
                }
                if let away = slot.away {
                    bind(statement, 5, away)
                } else {
                    sqlite3_bind_null(statement, 5)
                }
                // A separator that occurs in no channel name.
                bind(statement, 6, slot.channels.joined(separator: "\u{1F}"))
                if let land = slot.land {
                    bind(statement, 7, land)
                } else {
                    sqlite3_bind_null(statement, 7)
                }
                if let sportKind = slot.sportKind {
                    bind(statement, 8, sportKind)
                } else {
                    sqlite3_bind_null(statement, 8)
                }
                if let competition = slot.competition {
                    bind(statement, 9, competition)
                } else {
                    sqlite3_bind_null(statement, 9)
                }
                sqlite3_step(statement)
            }
        }
        sqlite3_finalize(statement)
        exec("COMMIT;")
    }

    // MARK: - Der gerechnete Spielplan

    /// How many computed schedules are kept.
    ///
    /// Four, for the same reason as in working memory: at most three
    /// day tabs and a reserve for the change of the stock state. Anything
    /// beyond that is a day that does not exist.
    static let maxSchedules = 4

    public func schedule(_ key: String) -> [SportEvent]? {
        guard (try? open()) != nil, let db = handle else { return nil }
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                db, "SELECT ereignisse FROM spielplan WHERE schluessel = ?;", -1, &statement, nil)
                == SQLITE_OK
        else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, key)
        guard sqlite3_step(statement) == SQLITE_ROW, let raw = text(statement, 0),
            let bytes = raw.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode([SportEvent].self, from: bytes)
    }

    public func setSchedule(_ events: [SportEvent], forItem key: String) {
        guard (try? open()) != nil, let db = handle,
            let bytes = try? JSONEncoder().encode(events),
            let raw = String(data: bytes, encoding: .utf8)
        else { return }

        var statement: OpaquePointer?
        if sqlite3_prepare_v2(
            db, "INSERT OR REPLACE INTO spielplan VALUES (?, ?, ?);", -1, &statement, nil)
            == SQLITE_OK
        {
            bind(statement, 1, key)
            bind(statement, 2, raw)
            sqlite3_bind_int64(statement, 3, Int64(Date().timeIntervalSince1970))
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)

        // The oldest goes as soon as there are too many — otherwise the
        // board would grow with every day that anyone has looked at once.
        //
        // **Sorting is by `rowid`, not by `created`.** The
        // timestamp is in whole seconds, and when the area is opened
        // several plans come into being in the same second — the order would then
        // be arbitrary, and the cleanup could throw away precisely the one just
        // written. That is exactly what happened during development.
        // `INSERT OR REPLACE` assigns a new `rowid`, so the sequence is
        // strictly increasing and storing again refreshes the row.
        exec(
            """
            DELETE FROM spielplan WHERE rowid NOT IN (
                SELECT rowid FROM spielplan ORDER BY rowid DESC LIMIT \(Self.maxSchedules)
            );
            """
        )
    }

    /// Throws away all computed schedules.
    ///
    /// Called when something has changed that the key does not see —
    /// new fixtures, a newly delivered guide with the same numbers.
    /// Same rationale as for ``ScheduleCalculator/clear()``: A store
    /// that conceals such a change would be worse than none.
    public func clearSchedules() {
        guard (try? open()) != nil else { return }
        exec("DELETE FROM spielplan;")
    }

    // MARK: - Notes on the cache

    public func note(_ key: String) -> String? {
        guard (try? open()) != nil, let db = handle else { return nil }
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(db, "SELECT wert FROM notiz WHERE schluessel = ?;", -1, &statement, nil)
                == SQLITE_OK
        else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, key)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return text(statement, 0)
    }

    public func setNote(_ value: String, forItem key: String) {
        guard (try? open()) != nil, let db = handle else { return }
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                db, "INSERT OR REPLACE INTO notiz (schluessel, wert) VALUES (?, ?);", -1,
                &statement, nil) == SQLITE_OK
        else { return }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, key)
        bind(statement, 2, value)
        _ = sqlite3_step(statement)
    }

    /// What the program stock yields at all: count and span.
    ///
    /// **The information that was missing on 2026-08-29** The single schedule row
    /// derived "stock empty or carries" from the number of *results* — that is,
    /// from what was left after all filters. That made an empty stock
    /// indistinguishable from a filter that eats everything. The same
    /// mix-up had already cost half a day once on 2026-08-16.
    public func programSpan() -> (count: Int, oldest: Date?, newest: Date?) {
        guard (try? open()) != nil, let db = handle else { return (0, nil, nil) }
        var statement: OpaquePointer?
        let sql = "SELECT COUNT(*), MIN(start), MAX(start) FROM programmes;"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return (0, nil, nil)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return (0, nil, nil) }
        let count = Int(sqlite3_column_int64(statement, 0))
        guard count > 0 else { return (0, nil, nil) }
        return (
            count,
            Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 1))),
            Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 2)))
        )
    }

    /// How far the **fixtures** reach — and why that is a second question.
    ///
    /// Since E6 the reach of the guide and that of the fixtures are two
    /// different numbers. The provider's guide is a rolling
    /// 48-hour window (measured 2026-08-29: earliest start 2026-08-28 10:19,
    /// latest 2026-08-30 10:19); the fixture source is queried over three days
    /// and knows of matches for which no broadcast is entered yet.
    ///
    /// Whoever derives the day tabs from the guide gives away exactly
    /// these days — after E7 that is, measured, eight rows on the third day
    /// that exist and are not displayed. That is why the number is given
    /// separately here and not guessed from ``programSpan()``.
    public func fixtureSpan() -> (count: Int, newest: Date?) {
        guard (try? open()) != nil, let db = handle else { return (0, nil) }
        var statement: OpaquePointer?
        let sql = "SELECT COUNT(*), MAX(start) FROM fixtures;"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return (0, nil)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return (0, nil) }
        let count = Int(sqlite3_column_int64(statement, 0))
        guard count > 0 else { return (0, nil) }
        return (
            count,
            Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 1)))
        )
    }

    /// How many programs lie in a window — without loading them.
    public func programCount(from start: Date, to end: Date) -> Int {
        guard (try? open()) != nil, let db = handle else { return 0 }
        var statement: OpaquePointer?
        let sql = "SELECT COUNT(*) FROM programmes WHERE stop > ? AND start < ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(start.timeIntervalSince1970))
        sqlite3_bind_int64(statement, 2, Int64(end.timeIntervalSince1970))
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    public enum Failure: Error { case cannotOpen }

    // MARK: - Sender

    /// Stores the channels of a list — as a whole, in the provider's
    /// order.
    ///
    /// **Delete first, then write, all in one go.** A channel that the
    /// provider removed must disappear; and a transaction is, for 5389 rows,
    /// not fine-tuning but the difference between one second and one minute —
    /// without it SQLite creates a journal of its own for each row.
    public func save(_ channels: [Channel], for playlistID: String) {
        guard (try? open()) != nil, let db = handle else { return }

        exec("BEGIN IMMEDIATE;")
        defer { exec("COMMIT;") }

        var delete: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM channels WHERE playlist = ?;", -1, &delete, nil)
            == SQLITE_OK
        {
            bind(delete, 1, playlistID)
            sqlite3_step(delete)
        }
        sqlite3_finalize(delete)

        var insert: OpaquePointer?
        let sql = """
            INSERT OR REPLACE INTO channels
            (id, playlist, name, grp, logo, epg, stream, adult, archive, position)
            VALUES (?,?,?,?,?,?,?,?,?,?);
            """
        guard sqlite3_prepare_v2(db, sql, -1, &insert, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(insert) }

        for (index, channel) in channels.enumerated() {
            sqlite3_reset(insert)
            bind(insert, 1, channel.id)
            bind(insert, 2, playlistID)
            bind(insert, 3, channel.name)
            bind(insert, 4, channel.group)
            bind(insert, 5, channel.logoURL?.absoluteString)
            bind(insert, 6, channel.epgID)
            bind(insert, 7, channel.streamURL.absoluteString)
            sqlite3_bind_int(insert, 8, channel.isAdult ? 1 : 0)
            if let days = channel.archiveDays {
                sqlite3_bind_int(insert, 9, Int32(days))
            } else {
                sqlite3_bind_null(insert, 9)
            }
            sqlite3_bind_int(insert, 10, Int32(index))
            sqlite3_step(insert)
        }

        // The timestamp decides whether to reload at the next open
        // — see ``channelsAreStale(now:maxAge:)``.
        exec("INSERT OR REPLACE INTO meta (id, saved) VALUES (1, strftime('%s','now'));")
    }

    /// Whether the channel catalog is old enough to reload it.
    ///
    /// Six hours: Providers rarely change their lists, and the app's most expensive
    /// fetch should not run on every opening of the sidebar.
    /// Whoever wants it immediately presses Refresh.
    public func channelsAreStale(now: Date = Date(), maxAge: TimeInterval = 6 * 3600) -> Bool {
        guard (try? open()) != nil else { return true }
        let saved = TimeInterval(channelsSavedAt)
        // No stamp means: never stored — then reloading is right.
        guard saved > 0 else { return true }
        return now.timeIntervalSince1970 - saved > maxAge
    }

    /// Wann zuletzt Sender abgelegt wurden — als Sekunden seit 1970.
    private var channelsSavedAt: Int {
        value(of: "SELECT COALESCE(MAX(saved), 0) FROM meta;")
    }

    /// The stored channels of a list, in the provider's order.
    public func channels(for playlistID: String) -> [Channel] {
        guard (try? open()) != nil, let db = handle else { return [] }

        var statement: OpaquePointer?
        let sql = """
            SELECT id, name, grp, logo, epg, stream, adult, archive
            FROM channels WHERE playlist = ? ORDER BY position;
            """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, playlistID)

        var result: [Channel] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = text(statement, 0), let name = text(statement, 1),
                let stream = text(statement, 5), let url = URL(string: stream)
            else { continue }

            result.append(
                Channel(
                    id: id,
                    name: name,
                    streamURL: url,
                    playlistID: playlistID,
                    group: text(statement, 2),
                    logoURL: text(statement, 3).flatMap(URL.init(string:)),
                    epgID: text(statement, 4),
                    isAdult: sqlite3_column_int(statement, 6) == 1,
                    archiveDays: sqlite3_column_type(statement, 7) == SQLITE_NULL
                        ? nil : Int(sqlite3_column_int(statement, 7))
                )
            )
        }
        return result
    }

    // MARK: - Programm

    /// Writes a batch of programs. For the sync, which reads in batches.
    public func save(programmes: [Programme]) {
        guard !programmes.isEmpty, (try? open()) != nil, let db = handle else { return }

        exec("BEGIN IMMEDIATE;")
        defer { exec("COMMIT;") }

        var insert: OpaquePointer?
        let sql = """
            INSERT OR REPLACE INTO programmes (id, epg, title, detail, start, stop)
            VALUES (?,?,?,?,?,?);
            """
        guard sqlite3_prepare_v2(db, sql, -1, &insert, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(insert) }

        for programs in programmes {
            sqlite3_reset(insert)
            bind(insert, 1, programs.id)
            bind(insert, 2, programs.channelID)
            bind(insert, 3, programs.title)
            bind(insert, 4, programs.description)
            sqlite3_bind_int64(insert, 5, Int64(programs.start.timeIntervalSince1970))
            sqlite3_bind_int64(insert, 6, Int64(programs.end.timeIntervalSince1970))
            sqlite3_step(insert)
        }
    }

    /// How far back the program reaches.
    ///
    /// **The day has a before, too** (viewer finding 2026-08-11: the program run is
    /// always cut off, earlier programs cannot be seen). Whoever wants to know
    /// what just ended — or what they missed — saw nothing:
    /// The window began at "now". Three hours cover the evening without
    /// having to scroll through the morning first.
    public static let guideLookBack: TimeInterval = 3 * 3600
    /// And how far ahead: the rest of the day and the night as well.
    public static let guideLookAhead: TimeInterval = 21 * 3600

    /// The program of a channel around a point in time.
    ///
    /// A window instead of "everything": Whoever read everything would hold, at three days per channel,
    /// a hundred entries in memory. The window is a **day around the point in
    /// time** — see ``guideLookBack`` and ``guideLookAhead``.
    public func programmes(
        epgID: String,
        around date: Date,
        limit: Int = 48,
        lookBack: TimeInterval = LiveCache.guideLookBack,
        lookAhead: TimeInterval = LiveCache.guideLookAhead
    ) -> [Programme] {
        guard !epgID.isEmpty, (try? open()) != nil, let db = handle else { return [] }

        var statement: OpaquePointer?
        // From the program that is already running at the earliest time: Hence
        // `stop >`, not `start >=` — otherwise the partly elapsed one would be missing.
        // And `start <` at the upper end, so that the boundary lies the same way there.
        let sql = """
            SELECT id, epg, title, detail, start, stop FROM programmes
            WHERE epg = ? AND stop > ? AND start < ? ORDER BY start LIMIT ?;
            """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        bind(statement, 1, epgID)
        sqlite3_bind_int64(statement, 2, Int64(date.addingTimeInterval(-lookBack).timeIntervalSince1970))
        sqlite3_bind_int64(statement, 3, Int64(date.addingTimeInterval(lookAhead).timeIntervalSince1970))
        sqlite3_bind_int(statement, 4, Int32(limit))

        var result: [Programme] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = text(statement, 0), let epg = text(statement, 1),
                let title = text(statement, 2)
            else { continue }

            result.append(
                Programme(
                    id: id,
                    channelID: epg,
                    title: title,
                    start: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 4))),
                    end: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 5))),
                    description: text(statement, 3)
                )
            )
        }
        return result
    }

    /// All programs of a period, across all channels — for the
    /// schedule.
    ///
    /// **By time, not by channel:** Sports also runs where the
    /// channel name gives no hint of it (Kanal 1 shows the Süper Lig). The
    /// schedule therefore reads the whole day and filters itself — at
    /// ~12,000 rows per day a computation of milliseconds, not a question to
    /// the network.
    /// - Parameter mitText: Whether the description comes along. **Default: no**
    ///   (E5). The schedule is the only consumer of this query, and
    ///   it reads the description nowhere — neither the detection nor the
    ///   row touches it. Reading it along would mean fetching, for every program of
    ///   the three-day window, a string from the database and
    ///   holding it in memory that nobody looks at. **This cannot be measured on the recording**
    ///   — it carries no text at all in 4,302 of 4,302 programs,
    ///   the tested provider does not fill `<desc>`. It is therefore demonstrated
    ///   with invented text at device size
    ///   (``ScheduleTimingTests``): 38,718 programs with 210 characters of
    ///   synopsis each cost 0.037 s with text and 0.015 s without.
    ///   Whoever needs the text says so — and sees at the call what it costs.
    public func programmes(from start: Date, to end: Date, withText: Bool = false) -> [Programme] {
        guard (try? open()) != nil, let db = handle else { return [] }

        var statement: OpaquePointer?
        // The same window logic as above: The partly elapsed program belongs
        // in (`stop >`), the one that begins only after the window does not.
        let sql =
            withText
            ? """
            SELECT id, epg, title, start, stop, detail FROM programmes
            WHERE stop > ? AND start < ? ORDER BY start;
            """
            : """
            SELECT id, epg, title, start, stop FROM programmes
            WHERE stop > ? AND start < ? ORDER BY start;
            """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, Int64(start.timeIntervalSince1970))
        sqlite3_bind_int64(statement, 2, Int64(end.timeIntervalSince1970))

        var result: [Programme] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = text(statement, 0), let epg = text(statement, 1),
                let title = text(statement, 2)
            else { continue }
            result.append(
                Programme(
                    id: id,
                    channelID: epg,
                    title: title,
                    start: Date(
                        timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 3))),
                    end: Date(
                        timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 4))),
                    description: withText ? text(statement, 5) : nil
                )
            )
        }
        return result
    }

    /// The running and the following programs of **many** channels at once.
    ///
    /// **One query instead of a hundred** (viewer finding 2026-08-08: only the top
    /// two rows show anything, the others load only on focus). The list
    /// shows for every row what is running right now — asking one by one meant, for
    /// a group with a hundred channels, a hundred round trips. The stock
    /// answers it in one go.
    public func programmes(
        epgIDs: [String], around date: Date, limitPerChannel: Int = 3
    ) -> [String: [Programme]] {
        let wanted = epgIDs.filter { !$0.isEmpty }
        guard !wanted.isEmpty, (try? open()) != nil, let db = handle else { return [:] }

        var result: [String: [Programme]] = [:]
        let stamp = Int64(date.timeIntervalSince1970)

        // In small batches, because SQLite limits the number of placeholders (999).
        var offset = 0
        while offset < wanted.count {
            let chunk = Array(wanted[offset..<min(offset + 400, wanted.count)])
            offset += 400

            let places = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let sql =
                "SELECT id, epg, title, detail, start, stop FROM programmes "
                + "WHERE epg IN (" + places + ") AND stop > ? ORDER BY epg, start;"

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { continue }

            for (index, id) in chunk.enumerated() {
                bind(statement, Int32(index + 1), id)
            }
            sqlite3_bind_int64(statement, Int32(chunk.count + 1), stamp)

            while sqlite3_step(statement) == SQLITE_ROW {
                guard let id = text(statement, 0), let epg = text(statement, 1),
                    let title = text(statement, 2)
                else { continue }
                // Only the first few per channel: The view shows no more,
                // and keeping everything would mean three days of program in memory.
                if (result[epg]?.count ?? 0) >= limitPerChannel { continue }

                result[epg, default: []].append(
                    Programme(
                        id: id,
                        channelID: epg,
                        title: title,
                        start: Date(
                            timeIntervalSince1970: TimeInterval(
                                sqlite3_column_int64(statement, 4))),
                        end: Date(
                            timeIntervalSince1970: TimeInterval(
                                sqlite3_column_int64(statement, 5))),
                        description: text(statement, 3)
                    )
                )
            }
            sqlite3_finalize(statement)
        }
        return result
    }

    /// The program of several channels in **one time window** — for the grid.
    ///
    /// **The difference from the query above** (AP14, 2026-09-02): That one answers
    /// "what is on now", the next three entries per channel. The grid
    /// asks something else — "what is on between 8 and 10 p.m." — and needs
    /// **everything** there, including the feature film that began at 7 p.m. and
    /// extends into it. Hence `stop > from` and not `stop > now`, and hence
    /// no upper limit per channel: A capped row would have a
    /// hole in the grid that looks like missing program and is not.
    ///
    /// Even so, what is loaded is never the world, but the visible window plus
    /// one screen in each direction — the caller decides that.
    public func programmes(
        epgIDs: [String], from start: Date, to end: Date
    )
        -> [String: [Programme]]
    {
        let wanted = epgIDs.filter { !$0.isEmpty }
        guard !wanted.isEmpty, end > start, (try? open()) != nil, let db = handle else {
            return [:]
        }

        var result: [String: [Programme]] = [:]
        let from = Int64(start.timeIntervalSince1970)
        let until = Int64(end.timeIntervalSince1970)

        // In small batches, because SQLite limits the number of placeholders (999).
        var offset = 0
        while offset < wanted.count {
            let chunk = Array(wanted[offset..<min(offset + 400, wanted.count)])
            offset += 400

            let places = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let sql =
                "SELECT id, epg, title, detail, start, stop FROM programmes "
                + "WHERE epg IN (" + places + ") AND stop > ? AND start < ? "
                + "ORDER BY epg, start;"

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { continue }

            for (index, id) in chunk.enumerated() {
                bind(statement, Int32(index + 1), id)
            }
            sqlite3_bind_int64(statement, Int32(chunk.count + 1), from)
            sqlite3_bind_int64(statement, Int32(chunk.count + 2), until)

            while sqlite3_step(statement) == SQLITE_ROW {
                guard let id = text(statement, 0), let epg = text(statement, 1),
                    let title = text(statement, 2)
                else { continue }
                result[epg, default: []].append(
                    Programme(
                        id: id,
                        channelID: epg,
                        title: title,
                        start: Date(
                            timeIntervalSince1970: TimeInterval(
                                sqlite3_column_int64(statement, 4))),
                        end: Date(
                            timeIntervalSince1970: TimeInterval(
                                sqlite3_column_int64(statement, 5))),
                        description: text(statement, 3)
                    )
                )
            }
            sqlite3_finalize(statement)
        }
        return result
    }

    // MARK: - Termine (Spielplan-Abgleich)

    /// Replaces the fixture catalog of **one source** — the other stays.
    ///
    /// **Why per source and not as a whole** (concept, section 3): Two
    /// sources that share the same catalog delete each other on every
    /// sync. Only their own rows are therefore deleted. Whoever wants to get rid of the
    /// other source says so explicitly
    /// (``removeFixtures(of:)``) — the fallback does exactly that, so that
    /// the two never stand side by side.
    public func save(fixtures: [SportFixture], of source: SportFixtureProvider) {
        guard !fixtures.isEmpty, (try? open()) != nil, let db = handle else { return }
        exec("BEGIN IMMEDIATE;")
        defer { exec("COMMIT;") }
        delete(source)

        var insert: OpaquePointer?
        let sql =
            "INSERT OR REPLACE INTO fixtures "
            + "(id, source, slug, sport, league, league_short, home, away, "
            + "home_alt, away_alt, start) "
            + "VALUES (?,?,?,?,?,?,?,?,?,?,?);"
        guard sqlite3_prepare_v2(db, sql, -1, &insert, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(insert) }

        for fixture in fixtures {
            sqlite3_reset(insert)
            bind(insert, 1, fixture.id)
            bind(insert, 2, fixture.source.rawValue)
            bind(insert, 3, fixture.path)
            bind(insert, 4, fixture.kind.rawValue)
            bind(insert, 5, fixture.league)
            bind(insert, 6, fixture.leagueShort)
            bind(insert, 7, fixture.home)
            bind(insert, 8, fixture.away)
            bind(insert, 9, Self.folded(fixture.homeVariantsList))
            bind(insert, 10, Self.folded(fixture.awayVariantsList))
            sqlite3_bind_int64(insert, 11, Int64(fixture.start.timeIntervalSince1970))
            sqlite3_step(insert)
        }
    }

    /// Throws away the fixtures of one source.
    public func removeFixtures(of source: SportFixtureProvider) {
        guard (try? open()) != nil, handle != nil else { return }
        delete(source)
    }

    private func delete(_ source: SportFixtureProvider) {
        guard let db = handle else { return }
        var delete: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM fixtures WHERE source = ?;", -1, &delete, nil)
            == SQLITE_OK
        {
            bind(delete, 1, source.rawValue)
            sqlite3_step(delete)
        }
        sqlite3_finalize(delete)
    }

    /// Several spellings in one column — separated by the tab character.
    ///
    /// A table of its own for four words per team would be one more joint
    /// that can break; the tab character occurs in no club name
    /// that either of the two sources delivers.
    static func folded(_ split: [String]) -> String? {
        split.isEmpty ? nil : split.joined(separator: "\t")
    }

    static func expanded(_ text: String?) -> [String] {
        guard let text, !text.isEmpty else { return [] }
        return text.components(separatedBy: "\t")
    }

    /// The fixtures of a time window.
    public func fixtures(from start: Date, to end: Date) -> [SportFixture] {
        guard (try? open()) != nil, let db = handle else { return [] }
        var statement: OpaquePointer?
        let sql =
            "SELECT id, source, slug, sport, league, league_short, home, away, "
            + "home_alt, away_alt, start "
            + "FROM fixtures WHERE start >= ? AND start < ? ORDER BY start;"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(start.timeIntervalSince1970))
        sqlite3_bind_int64(statement, 2, Int64(end.timeIntervalSince1970))

        var result: [SportFixture] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = text(statement, 0), let rawSource = text(statement, 1),
                let source = SportFixtureProvider(rawValue: rawSource),
                let path = text(statement, 2),
                let raw = text(statement, 3), let kind = SportKind(rawValue: raw),
                let league = text(statement, 4),
                let home = text(statement, 6), let away = text(statement, 7)
            else { continue }
            result.append(
                SportFixture(
                    id: id, source: source, path: path, kind: kind, league: league,
                    leagueShort: text(statement, 5) ?? "",
                    home: home, away: away,
                    start: Date(
                        timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 10))),
                    homeVariantsList: Self.expanded(text(statement, 8)),
                    awayVariantsList: Self.expanded(text(statement, 9))))
        }
        return result
    }

    /// How many fixtures really lie in the database.
    ///
    /// **The number that was missing until E6.** The trace line of the sync
    /// reported what was *fetched*, not what was *stored* — and ``save(fixtures:of:)``
    /// bails out silently if the database cannot be opened. Exactly
    /// this mix-up sent a whole troubleshooting session in the wrong direction for the programs on
    /// 2026-08-16; since then ``programmeCount()`` re-counts there, here until today nothing does.
    /// The comment at the old trace line itself flagged it.
    public func fixtureCount() -> Int {
        guard (try? open()) != nil else { return 0 }
        return value(of: "SELECT COUNT(*) FROM fixtures;")
    }

    /// How many of them come from a particular source.
    public func fixtureCount(of source: SportFixtureProvider) -> Int {
        guard (try? open()) != nil, let db = handle else { return 0 }
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                db, "SELECT COUNT(*) FROM fixtures WHERE source = ?;", -1, &statement, nil)
                == SQLITE_OK
        else { return 0 }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, source.rawValue)
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    // MARK: - Die lebende Sendertafel

    /// All observations — the stored rows of the channel board.
    ///
    /// There are few of them: one row per channel and competition, and a viewer
    /// has a few hundred sports channels. The board is therefore read
    /// as a whole and the rule computed in ``SportChannelBoard``, instead of writing it
    /// in SQL — a rule in SQL is a rule that no check
    /// reaches.
    public func channelCompetitions() -> [ChannelCompetition] {
        guard (try? open()) != nil, let db = handle else { return [] }
        var statement: OpaquePointer?
        let sql =
            "SELECT sender, pfad, herkunft, treffer, zuerst, zuletzt "
            + "FROM sender_wettbewerb ORDER BY sender, pfad;"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        var result: [ChannelCompetition] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let channels = text(statement, 0), let path = text(statement, 1),
                let rawOrigin = text(statement, 2),
                let origin = ChannelOrigin(rawValue: rawOrigin)
            else { continue }
            result.append(
                ChannelCompetition(
                    channels: channels, path: path, origin: origin,
                    match: Int(sqlite3_column_int64(statement, 3)),
                    firstSeen: Date(
                        timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 4))),
                    recent: Date(
                        timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 5)))))
        }
        return result
    }

    /// Writes the stock of the channel board — completely, not partially.
    ///
    /// The caller computed it beforehand with ``SportChannelBoard/merged(catalog:fresh:)``
    /// and ``SportChannelBoard/aged(_:now:)``. That the
    /// whole board is written here and not only the new part is deliberate: The
    /// **deletion** of the aged part is half the rule, and a partial
    /// write would have to catch it up separately. For a few hundred rows
    /// that costs nothing.
    public func setChannelCompetitions(_ rows: [ChannelCompetition]) {
        guard (try? open()) != nil, let db = handle else { return }
        exec("BEGIN IMMEDIATE;")
        defer { exec("COMMIT;") }
        exec("DELETE FROM sender_wettbewerb;")
        guard !rows.isEmpty else { return }

        var insert: OpaquePointer?
        let sql =
            "INSERT OR REPLACE INTO sender_wettbewerb "
            + "(sender, pfad, herkunft, treffer, zuerst, zuletzt) VALUES (?,?,?,?,?,?);"
        guard sqlite3_prepare_v2(db, sql, -1, &insert, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(insert) }
        for row in rows {
            sqlite3_reset(insert)
            bind(insert, 1, row.channels)
            bind(insert, 2, row.path)
            bind(insert, 3, row.origin.rawValue)
            sqlite3_bind_int64(insert, 4, Int64(row.match))
            sqlite3_bind_int64(insert, 5, Int64(row.firstSeen.timeIntervalSince1970))
            sqlite3_bind_int64(insert, 6, Int64(row.recent.timeIntervalSince1970))
            sqlite3_step(insert)
        }
    }

    /// Whether any program is stored at all — decides whether the view
    /// has to ask.
    public func hasProgrammes() -> Bool {
        programmeCount() > 0
    }

    /// How many programs really lie in the database.
    ///
    /// For the honest sync measurement: The parser's counter counts
    /// what was read — whether it arrived, only the database itself knows (on-device finding
    /// 2026-08-16: "61,026 in stock" reported, zero stored).
    public func programmeCount() -> Int {
        guard (try? open()) != nil else { return 0 }
        return value(of: "SELECT COUNT(*) FROM programmes;")
    }

    /// Clears out the past.
    public func pruneProgrammes(now: Date = Date()) {
        guard (try? open()) != nil, let db = handle else { return }
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(db, "DELETE FROM programmes WHERE stop < ?;", -1, &statement, nil)
                == SQLITE_OK
        else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(
            statement, 1, Int64(now.addingTimeInterval(-Self.keepBackward).timeIntervalSince1970))
        sqlite3_step(statement)
    }

    /// Throws everything away — when deleting a list or signing out.
    public func clear() {
        guard (try? open()) != nil else { return }
        exec("DELETE FROM programmes;")
        exec("DELETE FROM channels;")
    }

    // MARK: - Kleinkram

    private func exec(_ sql: String) {
        guard let handle else { return }
        sqlite3_exec(handle, sql, nil, nil, nil)
    }

    private func value(of sql: String) -> Int {
        guard let handle else { return 0 }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int(statement, 0)) : 0
    }

    /// `SQLITE_TRANSIENT`: SQLite must **copy** the string. Without that
    /// the pointer points into nothing after return — the error shows up
    /// as random garbage data in the database, not as a crash.
    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        guard let raw = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: raw)
    }
}
