import Foundation

/// A parsed iCalendar (RFC 5545) document — the payload of a `text/calendar`
/// attachment, typically a meeting invite with a single `VEVENT`.
///
/// iOS offers no system path from a third-party app into Calendar for `.ics`
/// files: Apple Calendar ships no share-sheet extension, QuickLook shows the
/// event but has no Add button, and only Apple Mail / Safari get the
/// privileged import flow. So the client parses the invite itself and hands a
/// prefilled `EKEvent` to `EKEventEditViewController` (which since iOS 17
/// runs out-of-process and needs no calendar permission). This type is the
/// parser's output: deliberately EventKit-free so it stays testable under
/// `swift test` on every platform the Kit supports.
public struct ICalendar: Sendable, Equatable {
    /// The iTIP `METHOD` (`REQUEST`, `CANCEL`, `PUBLISH`, …), uppercased.
    /// Nil when the sender omitted it (common for plain event exports).
    public let method: String?
    public let events: [ICalendarEvent]

    public init(method: String?, events: [ICalendarEvent]) {
        self.method = method
        self.events = events
    }

    /// Whether an attachment should be treated as a calendar invite. Keys on
    /// the declared MIME type, falling back to the filename extension for
    /// senders that ship `.ics` as `application/octet-stream`.
    public static func isCalendarAttachment(mimeType: String, filename: String?) -> Bool {
        let mime = mimeType.lowercased()
        if mime == "text/calendar" || mime == "application/ics" { return true }
        return filename?.lowercased().hasSuffix(".ics") == true
    }
}

/// A single `VEVENT`. All text fields are RFC 5545-unescaped (`\n`, `\,`,
/// `\;`, `\\`).
public struct ICalendarEvent: Sendable, Equatable {
    /// A `DTSTART`/`DTEND` value. `date` is the resolved absolute instant;
    /// `isDateOnly` marks all-day values (`VALUE=DATE`), which are anchored
    /// at UTC midnight so parsing is machine-independent — consumers convert
    /// to a local wall-clock date via `resolved(in:)`. `timeZone` is the
    /// zone the sender specified (`TZID=` or UTC for `...Z`); nil for
    /// floating times and all-day dates.
    public struct EventDate: Sendable, Equatable {
        public let date: Date
        public let isDateOnly: Bool
        public let timeZone: TimeZone?

        public init(date: Date, isDateOnly: Bool, timeZone: TimeZone?) {
            self.date = date
            self.isDateOnly = isDateOnly
            self.timeZone = timeZone
        }

        /// The instant to hand to a calendar UI: timed values pass through,
        /// all-day values re-anchor their UTC-midnight components to
        /// midnight in `calendar`'s zone.
        public func resolved(in calendar: Calendar = .current) -> Date {
            guard isDateOnly else { return date }
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(identifier: "UTC") ?? .current
            let components = utc.dateComponents([.year, .month, .day], from: date)
            return calendar.date(from: components) ?? date
        }
    }

    public let uid: String?
    public let summary: String?
    public let description: String?
    public let location: String?
    public let url: URL?
    /// Display string for the organizer: `CN` name, address, or both
    /// (`Ada Lovelace <ada@example.com>`).
    public let organizer: String?
    /// Display strings for attendees, same format as `organizer`.
    public let attendees: [String]
    public let start: EventDate?
    public let end: EventDate?
    public let recurrence: ICalendarRecurrenceRule?
    /// The verbatim `RRULE` value whenever the event recurs, including rules
    /// too complex for `RecurrenceRule`. Nil for non-recurring events.
    public let recurrenceRaw: String?
    /// `STATUS` value uppercased (`CONFIRMED`, `CANCELLED`, `TENTATIVE`).
    public let status: String?

    public init(
        uid: String?,
        summary: String?,
        description: String?,
        location: String?,
        url: URL?,
        organizer: String?,
        attendees: [String],
        start: EventDate?,
        end: EventDate?,
        recurrence: ICalendarRecurrenceRule?,
        recurrenceRaw: String?,
        status: String?
    ) {
        self.uid = uid
        self.summary = summary
        self.description = description
        self.location = location
        self.url = url
        self.organizer = organizer
        self.attendees = attendees
        self.start = start
        self.end = end
        self.recurrence = recurrence
        self.recurrenceRaw = recurrenceRaw
        self.status = status
    }
}

/// The subset of `RRULE` this client can represent faithfully. When the
/// sender's rule uses anything beyond these fields the parser returns no
/// `recurrence` at all (a wrong repeat pattern on the imported event is
/// worse than none) and callers fall back to `recurrenceRaw` for display.
public struct ICalendarRecurrenceRule: Sendable, Equatable {
    public enum Frequency: String, Sendable {
        case daily = "DAILY"
        case weekly = "WEEKLY"
        case monthly = "MONTHLY"
        case yearly = "YEARLY"
    }

    public enum Weekday: String, Sendable, CaseIterable {
        case sunday = "SU"
        case monday = "MO"
        case tuesday = "TU"
        case wednesday = "WE"
        case thursday = "TH"
        case friday = "FR"
        case saturday = "SA"
    }

    public let frequency: Frequency
    public let interval: Int
    public let count: Int?
    public let until: Date?
    /// Plain (ordinal-free) `BYDAY` weekdays; only produced for `WEEKLY`
    /// rules, where they are unambiguous.
    public let byDay: [Weekday]

    public init(frequency: Frequency, interval: Int, count: Int?, until: Date?, byDay: [Weekday]) {
        self.frequency = frequency
        self.interval = interval
        self.count = count
        self.until = until
        self.byDay = byDay
    }
}
