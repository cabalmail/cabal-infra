import Foundation

/// Minimal RFC 5545 parser: enough to turn the calendar invites that arrive
/// as mail attachments into `ICalendar` values. It is deliberately not a
/// general iCalendar implementation — `VTIMEZONE` definitions are skipped
/// (`TZID` values are resolved against the system database instead, which
/// covers IANA identifiers; unresolvable zones degrade to floating time),
/// and `RRULE` support is bounded (see `ICalendarRecurrenceRule`).
public enum ICalendarParser {
    /// Parses raw attachment bytes as UTF-8 (invalid sequences are replaced,
    /// not fatal). Returns nil when the payload has no `BEGIN:VCALENDAR`.
    public static func parse(_ data: Data) -> ICalendar? {
        // Lossy decoding is the point: a stray non-UTF-8 byte in one property
        // must not discard the whole invite, so no failable init here.
        // swiftlint:disable:next optional_data_string_conversion
        parse(String(decoding: data, as: UTF8.self))
    }

    public static func parse(_ text: String) -> ICalendar? {
        let lines = unfoldedLines(text)
        guard lines.contains(where: { $0.uppercased().hasPrefix("BEGIN:VCALENDAR") }) else {
            return nil
        }
        var method: String?
        var events: [ICalendarEvent] = []
        var index = 0
        while index < lines.count {
            guard let line = ContentLine(lines[index]) else {
                index += 1
                continue
            }
            switch line.name {
            case "BEGIN" where line.value.uppercased() == "VEVENT":
                let (event, next) = parseEvent(lines, from: index + 1)
                if let event { events.append(event) }
                index = next
            case "METHOD":
                method = line.value.uppercased()
                index += 1
            default:
                index += 1
            }
        }
        return ICalendar(method: method, events: events)
    }

    /// Splits on CR/LF and reverses RFC 5545 §3.1 folding: a line beginning
    /// with a space or tab continues the previous line (the leading
    /// whitespace octet is discarded).
    static func unfoldedLines(_ text: String) -> [String] {
        let lineBreaks: Set<Character> = ["\r\n", "\n", "\r"]
        var lines: [String] = []
        for raw in text.split(omittingEmptySubsequences: true, whereSeparator: { lineBreaks.contains($0) }) {
            if let first = raw.first, first == " " || first == "\t", !lines.isEmpty {
                lines[lines.count - 1] += raw.dropFirst()
            } else {
                lines.append(String(raw))
            }
        }
        return lines
    }
}

/// One unfolded `name;param=value:value` content line. Parameter names are
/// uppercased; quoted parameter values keep their content verbatim.
struct ContentLine {
    let name: String
    let parameters: [String: String]
    let value: String

    init?(_ line: String) {
        // Find the value delimiter — the first ':' outside DQUOTEs.
        var inQuotes = false
        var colonIndex: String.Index?
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "\"" { inQuotes.toggle() }
            if character == ":", !inQuotes {
                colonIndex = index
                break
            }
            index = line.index(after: index)
        }
        guard let colonIndex else { return nil }
        let head = line[line.startIndex..<colonIndex]
        value = String(line[line.index(after: colonIndex)...])
        let segments = Self.splitOutsideQuotes(head, on: ";")
        guard let nameSegment = segments.first, !nameSegment.isEmpty else { return nil }
        name = nameSegment.uppercased()
        var parameters: [String: String] = [:]
        for segment in segments.dropFirst() {
            guard let equals = segment.firstIndex(of: "=") else { continue }
            let key = String(segment[segment.startIndex..<equals]).uppercased()
            var parameterValue = String(segment[segment.index(after: equals)...])
            parameterValue = parameterValue.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            parameters[key] = parameterValue
        }
        self.parameters = parameters
    }

    private static func splitOutsideQuotes(_ text: Substring, on separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        for character in text {
            if character == "\"" { inQuotes.toggle() }
            if character == separator, !inQuotes {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        return parts
    }
}

extension ICalendarParser {
    /// Consumes lines from `start` (just past `BEGIN:VEVENT`) to the matching
    /// `END:VEVENT`, skipping nested components (`VALARM`). Returns the event
    /// and the index just past the terminator.
    static func parseEvent(_ lines: [String], from start: Int) -> (ICalendarEvent?, Int) {
        var properties: [ContentLine] = []
        var index = start
        var nestedDepth = 0
        while index < lines.count {
            guard let line = ContentLine(lines[index]) else {
                index += 1
                continue
            }
            index += 1
            switch line.name {
            case "BEGIN":
                nestedDepth += 1
            case "END" where nestedDepth > 0:
                nestedDepth -= 1
            case "END" where line.value.uppercased() == "VEVENT":
                return (buildEvent(from: properties), index)
            default:
                if nestedDepth == 0 { properties.append(line) }
            }
        }
        // Truncated input: no END:VEVENT. Drop the partial event.
        return (nil, index)
    }

    private static func buildEvent(from properties: [ContentLine]) -> ICalendarEvent {
        var fields: [String: ContentLine] = [:]
        var attendees: [String] = []
        for property in properties {
            if property.name == "ATTENDEE" {
                attendees.append(participantDisplay(property))
            } else {
                fields[property.name] = fields[property.name] ?? property
            }
        }
        let start = fields["DTSTART"].flatMap(eventDate(from:))
        let rrule = fields["RRULE"]?.value
        return ICalendarEvent(
            uid: fields["UID"]?.value,
            summary: fields["SUMMARY"].map { unescapeText($0.value) },
            description: fields["DESCRIPTION"].map { unescapeText($0.value) },
            location: fields["LOCATION"].map { unescapeText($0.value) },
            url: fields["URL"].flatMap { URL(string: $0.value) },
            organizer: fields["ORGANIZER"].map(participantDisplay),
            attendees: attendees,
            start: start,
            end: eventEnd(fields: fields, start: start),
            recurrence: rrule.flatMap(recurrenceRule(from:)),
            recurrenceRaw: rrule,
            status: fields["STATUS"]?.value.uppercased()
        )
    }

    /// `DTEND` when present, else `DTSTART + DURATION`, else nil.
    private static func eventEnd(
        fields: [String: ContentLine],
        start: ICalendarEvent.EventDate?
    ) -> ICalendarEvent.EventDate? {
        if let end = fields["DTEND"].flatMap(eventDate(from:)) { return end }
        guard let start, let duration = fields["DURATION"].flatMap({ durationSeconds($0.value) }) else {
            return nil
        }
        return ICalendarEvent.EventDate(
            date: start.date.addingTimeInterval(duration),
            isDateOnly: start.isDateOnly,
            timeZone: start.timeZone
        )
    }

    /// `Ada Lovelace <ada@example.com>` from `ORGANIZER;CN=Ada Lovelace:mailto:ada@example.com`,
    /// degrading to whichever half the sender provided.
    private static func participantDisplay(_ line: ContentLine) -> String {
        let address = line.value.lowercased().hasPrefix("mailto:")
            ? String(line.value.dropFirst("mailto:".count))
            : line.value
        guard let name = line.parameters["CN"], !name.isEmpty, name != address else {
            return address
        }
        return address.isEmpty ? name : "\(name) <\(address)>"
    }

    /// RFC 5545 §3.3.11 text unescaping.
    static func unescapeText(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var iterator = text.makeIterator()
        while let character = iterator.next() {
            guard character == "\\", let escaped = iterator.next() else {
                result.append(character)
                continue
            }
            switch escaped {
            case "n", "N": result.append("\n")
            default: result.append(escaped)
            }
        }
        return result
    }
}

extension ICalendarParser {
    /// Parses `DATE` (`19970714`) and `DATE-TIME` (`19970714T133000`,
    /// optionally suffixed `Z` or qualified by `TZID=`). Returns nil on
    /// malformed values. All-day dates anchor at UTC midnight (see
    /// `EventDate`); floating times resolve in the current zone.
    static func eventDate(from line: ContentLine) -> ICalendarEvent.EventDate? {
        let value = line.value.trimmingCharacters(in: .whitespaces)
        let isDateOnly = line.parameters["VALUE"]?.uppercased() == "DATE" || value.count == 8
        var calendar = Calendar(identifier: .gregorian)
        var components = DateComponents()
        guard let year = Int(value.prefix(4)),
              let month = Int(value.dropFirst(4).prefix(2)),
              let day = Int(value.dropFirst(6).prefix(2)) else { return nil }
        components.year = year
        components.month = month
        components.day = day
        if isDateOnly {
            calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
            guard let date = calendar.date(from: components) else { return nil }
            return ICalendarEvent.EventDate(date: date, isDateOnly: true, timeZone: nil)
        }
        let time = value.dropFirst(8)
        guard time.first == "T", time.count >= 7,
              let hour = Int(time.dropFirst(1).prefix(2)),
              let minute = Int(time.dropFirst(3).prefix(2)),
              let second = Int(time.dropFirst(5).prefix(2)) else { return nil }
        components.hour = hour
        components.minute = minute
        components.second = second
        let zone: TimeZone?
        if value.hasSuffix("Z") {
            zone = TimeZone(identifier: "UTC")
        } else {
            zone = line.parameters["TZID"].flatMap { TimeZone(identifier: $0) }
        }
        calendar.timeZone = zone ?? .current
        guard let date = calendar.date(from: components) else { return nil }
        return ICalendarEvent.EventDate(date: date, isDateOnly: false, timeZone: zone)
    }

    /// RFC 5545 §3.3.6 `DURATION` (`P1DT2H30M`, `PT45M`, `P2W`) in seconds.
    /// Negative durations (legal in the grammar, nonsensical for an event
    /// length) and malformed values return nil.
    static func durationSeconds(_ value: String) -> TimeInterval? {
        var rest = Substring(value.uppercased())
        if rest.hasPrefix("+") { rest = rest.dropFirst() }
        guard !rest.hasPrefix("-"), rest.first == "P" else { return nil }
        rest = rest.dropFirst()
        var total: TimeInterval = 0
        var sawComponent = false
        let unitSeconds: [Character: TimeInterval] = ["W": 604_800, "D": 86_400, "H": 3_600, "M": 60, "S": 1]
        while let character = rest.first {
            if character == "T" {
                rest = rest.dropFirst()
                continue
            }
            let digits = rest.prefix(while: \.isNumber)
            rest = rest.dropFirst(digits.count)
            guard let quantity = Int(digits), let unit = rest.first, let seconds = unitSeconds[unit] else {
                return nil
            }
            total += TimeInterval(quantity) * seconds
            sawComponent = true
            rest = rest.dropFirst()
        }
        return sawComponent ? total : nil
    }

    /// Maps an `RRULE` value onto the bounded `RecurrenceRule` model.
    /// Returns nil for any rule using parts the model can't carry
    /// (`BYMONTHDAY`, `BYSETPOS`, ordinal `BYDAY`, non-weekly `BYDAY`, …) —
    /// importing those with dropped qualifiers would repeat on the wrong days.
    static func recurrenceRule(from value: String) -> ICalendarRecurrenceRule? {
        var parts: [String: String] = [:]
        for pair in value.split(separator: ";") {
            guard let equals = pair.firstIndex(of: "=") else { return nil }
            parts[pair[..<equals].uppercased()] = String(pair[pair.index(after: equals)...])
        }
        guard let frequency = parts.removeValue(forKey: "FREQ")
            .flatMap({ ICalendarRecurrenceRule.Frequency(rawValue: $0.uppercased()) }) else {
            return nil
        }
        let interval = parts.removeValue(forKey: "INTERVAL").flatMap(Int.init) ?? 1
        let count = parts.removeValue(forKey: "COUNT").flatMap(Int.init)
        let until = parts.removeValue(forKey: "UNTIL").flatMap { untilDate($0) }
        parts.removeValue(forKey: "WKST") // Week start only matters for rules we reject anyway.
        var byDay: [ICalendarRecurrenceRule.Weekday] = []
        if let byDayValue = parts.removeValue(forKey: "BYDAY") {
            guard frequency == .weekly else { return nil }
            for day in byDayValue.split(separator: ",") {
                guard let weekday = ICalendarRecurrenceRule.Weekday(rawValue: day.uppercased()) else {
                    return nil // Ordinal-prefixed (1MO) or malformed entries.
                }
                byDay.append(weekday)
            }
        }
        guard parts.isEmpty else { return nil }
        return ICalendarRecurrenceRule(
            frequency: frequency,
            interval: interval,
            count: count,
            until: until,
            byDay: byDay
        )
    }

    private static func untilDate(_ value: String) -> Date? {
        guard let line = ContentLine("DTSTART:\(value)") else { return nil }
        return eventDate(from: line)?.resolved()
    }
}
