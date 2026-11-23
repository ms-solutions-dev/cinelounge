import Core
import Foundation

/// Reads an M3U channel list.
///
/// **Foreign lists are untidy, and edge cases are the normal case here.** This
/// is not a guess but the most frequent complaint about comparable apps: A
/// list that works elsewhere is rejected or only half read. That is why
/// the rule here throughout is: **What can be read is read; what cannot is
/// skipped — the whole list never breaks on one line.**
///
/// The structure of an M3U is simple, reality less so:
///
/// ```
/// #EXTM3U
/// #EXTINF:-1 tvg-id=`ahorn.de` tvg-logo="http://…/ahorn.png" group-title="DE · Öffentlich",Das Nordlicht HD
/// http://server/stream/1
/// ```
///
/// What deviates from it in real lists — each point is handled here and recorded in
/// the test cases:
///
/// - Attributes in any order, with or without quotation marks
/// - The display name comes after the **last** comma; commas in attribute values
///   must not cut it off
/// - Groups either as `group-title` or as a separate line `#EXTGRP:`
/// - Lines such as `#EXTVLCOPT:` in between that have nothing to do with the channel
/// - A byte order mark at the start of the file
/// - Windows line endings, blank lines, duplicate entries
/// - Entries without an address at the end of the file
public enum M3UParser {

    /// Parses the contents of an M3U file.
    ///
    /// - Parameter playlistID: ID of the channel list the channels come
    ///   from. It is part of the channel ID, so that the same channel from
    ///   two lists does not count as one.
    public static func parse(_ text: String, playlistID: String = "") -> [Channel] {
        var channels: [Channel] = []
        var pending: PartialEntry?
        var seen = Set<String>()

        for rawLine in normalize(text).split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("#EXTINF:") {
                // A new entry begins. A previous one without an address lapses
                // here — it would be a channel that cannot be played.
                pending = PartialEntry(extinf: String(line.dropFirst("#EXTINF:".count)))

            } else if line.hasPrefix("#EXTGRP:") {
                // The older notation for the group. It comes **after** the
                // info line and applies only if no group was named there.
                let group = line.dropFirst("#EXTGRP:".count).trimmingCharacters(in: .whitespaces)
                if pending?.group == nil, !group.isEmpty {
                    pending?.group = group
                }

            } else if line.hasPrefix("#") {
                // Everything else with a hash does not belong to the channel:
                // `#EXTVLCOPT:`, `#EXTM3U`, comments. Skip it without discarding
                // the entry that has begun.
                continue

            } else if var entry = pending {
                // The first line without a hash is the address.
                entry.url = line
                pending = nil

                guard let channel = entry.build(playlistID: playlistID, ordinal: channels.count)
                else { continue }

                // Duplicates occur constantly in merged lists. The
                // first one wins — it comes from the source that was named first,
                // and that is usually the preferred one.
                //
                // Comparison is by name **and** address: Two entries with the
                // same name but a different address are usually two
                // resolutions of the same channel, and keeping both is
                // right — one wants the choice.
                let key = "\(channel.cleanName.lowercased())|\(channel.streamURL.absoluteString)"
                guard seen.insert(key).inserted else { continue }
                channels.append(channel)
            }
        }

        return channels
    }

    // MARK: - Vorbereitung

    /// Normalizes what line-by-line reading would otherwise fail on.
    static func normalize(_ text: String) -> String {
        var out = text

        // The byte order mark sits invisibly at the start of the file and
        // otherwise sticks to the first `#EXTM3U`, which is then not recognized.
        if out.hasPrefix("\u{FEFF}") {
            out.removeFirst()
        }

        // Bring Windows and old Mac line endings to a uniform character.
        return out.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    // MARK: - Ein halber Eintrag

    /// Intermediate state between info line and address.
    struct PartialEntry {
        var attributes: [String: String]
        var name: String
        var group: String?
        var duration: Double?
        var url: String?

        init(extinf: String) {
            let (head, title) = Self.split(extinf)
            self.attributes = Self.attributes(in: head)
            self.name = title
            self.group = attributes["group-title"]
            self.duration = Double(head.prefix(while: { $0 == "-" || $0.isNumber || $0 == "." }))
        }

        /// Separates the head with the details from the display name.
        ///
        /// Splitting is at the **last** comma, not the first: Attribute values
        /// regularly contain commas — `group-title="Sport, national"` — and
        /// splitting at the first would turn that into a channel named `national"`.
        static func split(_ extinf: String) -> (head: String, title: String) {
            guard let comma = extinf.lastIndex(of: ",") else {
                return (extinf, "")
            }
            return (
                String(extinf[extinf.startIndex..<comma]),
                String(extinf[extinf.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
            )
        }

        /// Reads `key="value"` and `key=value` from the head.
        ///
        /// By hand and not with a search pattern: The values contain
        /// quotation marks, equals signs and commas in every combination.
        /// A pattern that covers all that can no longer be read — and certainly not
        /// changed when a list looks different after all.
        ///
        /// The pass is deliberately plain: key up to the equals sign,
        /// then the value — in quotation marks up to the closing one, without up to the
        /// next space. Everything before and in between is skipped,
        /// including the duration at the start of the line.
        static func attributes(in head: String) -> [String: String] {
            var result: [String: String] = [:]
            let characters = Array(head)
            var index = 0

            while index < characters.count {
                // Advance to the start of a key. Keys consist of
                // letters and hyphens — the duration at the start does not.
                guard characters[index].isLetter else {
                    index += 1
                    continue
                }

                var key = ""
                while index < characters.count, characters[index] != "=", characters[index] != " " {
                    key.append(characters[index])
                    index += 1
                }

                // A word without an equals sign is not an attribute.
                guard index < characters.count, characters[index] == "=" else { continue }
                index += 1

                var value = ""
                if index < characters.count, characters[index] == "\"" {
                    index += 1
                    while index < characters.count, characters[index] != "\"" {
                        value.append(characters[index])
                        index += 1
                    }
                    index += 1  // the closing quotation mark
                } else {
                    while index < characters.count, characters[index] != " " {
                        value.append(characters[index])
                        index += 1
                    }
                }

                if !key.isEmpty {
                    result[key.lowercased()] = value
                }
            }

            return result
        }

        /// Builds a channel from it — or nothing if something essential is missing.
        func build(playlistID: String, ordinal: Int) -> Channel? {
            guard let url, let streamURL = URL(string: url), streamURL.scheme != nil else {
                return nil
            }

            // Without a name the channel could not be found in the list. Some
            // lists omit it and carry it only as an attribute.
            let title = name.isEmpty ? (attributes["tvg-name"] ?? "") : name
            guard !title.isEmpty else { return nil }

            // The running number belongs in the ID: Some lists carry
            // the same channel several times without their own `tvg-id`, and without it
            // those would be two entries with the same ID — the display would then show
            // only one and the focus would jump.
            return Channel(
                id: "\(playlistID)#\(attributes["tvg-id"] ?? title)#\(ordinal)",
                name: title,
                streamURL: streamURL,
                playlistID: playlistID,
                group: group,
                logoURL: attributes["tvg-logo"].flatMap(URL.init(string:)),
                // The ID for the program guide. Without it there is later
                // no program for this channel.
                epgID: attributes["tvg-id"]
            )
        }
    }
}
