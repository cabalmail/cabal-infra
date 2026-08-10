import XCTest
@testable import CabalmailKit

final class ICalendarParserTests: XCTestCase {
    // A representative Google-style invite: folded DESCRIPTION, TZID-qualified
    // times, organizer + attendees, an alarm block to skip.
    func testParsesSingleEventInvite() throws {
        let ics = [
            "BEGIN:VCALENDAR",
            "PRODID:-//Test//EN",
            "VERSION:2.0",
            "METHOD:REQUEST",
            "BEGIN:VEVENT",
            "DTSTART;TZID=America/New_York:20260915T140000",
            "DTEND;TZID=America/New_York:20260915T150000",
            "UID:abc-123@example.com",
            "ORGANIZER;CN=Ada Lovelace:mailto:ada@example.com",
            "ATTENDEE;CN=Grace Hopper;PARTSTAT=NEEDS-ACTION:mailto:grace@example.com",
            "ATTENDEE:mailto:alan@example.com",
            "SUMMARY:Planning\\, part 2",
            "DESCRIPTION:Line one.\\nLine two with a long tail that the sender",
            " folded onto a continuation line.",
            "LOCATION:Room 4",
            "URL:https://example.com/meet/1",
            "STATUS:CONFIRMED",
            "BEGIN:VALARM",
            "TRIGGER:-PT10M",
            "ACTION:DISPLAY",
            "END:VALARM",
            "END:VEVENT",
            "END:VCALENDAR",
        ].joined(separator: "\r\n")

        let calendar = try XCTUnwrap(ICalendarParser.parse(Data(ics.utf8)))
        XCTAssertEqual(calendar.method, "REQUEST")
        XCTAssertEqual(calendar.events.count, 1)
        let event = try XCTUnwrap(calendar.events.first)
        XCTAssertEqual(event.uid, "abc-123@example.com")
        XCTAssertEqual(event.summary, "Planning, part 2")
        XCTAssertEqual(
            event.description,
            "Line one.\nLine two with a long tail that the senderfolded onto a continuation line."
        )
        XCTAssertEqual(event.location, "Room 4")
        XCTAssertEqual(event.url, URL(string: "https://example.com/meet/1"))
        XCTAssertEqual(event.organizer, "Ada Lovelace <ada@example.com>")
        XCTAssertEqual(event.attendees, ["Grace Hopper <grace@example.com>", "alan@example.com"])
        XCTAssertEqual(event.status, "CONFIRMED")
        XCTAssertNil(event.recurrence)
        XCTAssertNil(event.recurrenceRaw)
        try assertInviteTimes(event)
    }

    /// The single-event invite's DTSTART/DTEND: 2:00–3:00 PM New York time.
    private func assertInviteTimes(_ event: ICalendarEvent) throws {
        let start = try XCTUnwrap(event.start)
        XCTAssertFalse(start.isDateOnly)
        XCTAssertEqual(start.timeZone?.identifier, "America/New_York")
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let components = newYork.dateComponents([.year, .month, .day, .hour, .minute], from: start.date)
        XCTAssertEqual([components.year, components.month, components.day], [2026, 9, 15])
        XCTAssertEqual([components.hour, components.minute], [14, 0])
        let end = try XCTUnwrap(event.end)
        XCTAssertEqual(end.date.timeIntervalSince(start.date), 3600)
    }

    func testParsesUTCDateTime() throws {
        let event = try firstEvent([
            "DTSTART:20260101T090000Z",
            "DTEND:20260101T093000Z",
        ])
        let start = try XCTUnwrap(event.start)
        XCTAssertEqual(start.timeZone?.secondsFromGMT(), 0)
        // 2026-01-01T09:00:00Z as an absolute instant.
        XCTAssertEqual(start.date, Date(timeIntervalSince1970: 1_767_258_000))
        XCTAssertEqual(event.end?.date, start.date.addingTimeInterval(1800))
    }

    func testParsesAllDayDate() throws {
        let event = try firstEvent([
            "DTSTART;VALUE=DATE:20260810",
            "DTEND;VALUE=DATE:20260811",
        ])
        let start = try XCTUnwrap(event.start)
        XCTAssertTrue(start.isDateOnly)
        XCTAssertNil(start.timeZone)
        // Anchored at UTC midnight regardless of the machine's zone…
        XCTAssertEqual(start.date, Date(timeIntervalSince1970: 1_786_320_000))
        // …and resolvable to local midnight of the same wall-clock date.
        var local = Calendar(identifier: .gregorian)
        local.timeZone = TimeZone(identifier: "Pacific/Auckland") ?? .current
        let resolved = local.dateComponents([.year, .month, .day, .hour], from: start.resolved(in: local))
        XCTAssertEqual([resolved.year, resolved.month, resolved.day, resolved.hour], [2026, 8, 10, 0])
    }

    func testDurationProducesEndWhenDTENDMissing() throws {
        let event = try firstEvent([
            "DTSTART:20260101T090000Z",
            "DURATION:PT1H30M",
        ])
        let start = try XCTUnwrap(event.start?.date)
        XCTAssertEqual(event.end?.date, start.addingTimeInterval(5400))
    }

    func testDurationGrammar() {
        XCTAssertEqual(ICalendarParser.durationSeconds("P2W"), 1_209_600)
        XCTAssertEqual(ICalendarParser.durationSeconds("P1DT2H3M4S"), 93_784)
        XCTAssertEqual(ICalendarParser.durationSeconds("PT45M"), 2700)
        XCTAssertNil(ICalendarParser.durationSeconds("-PT1H"))
        XCTAssertNil(ICalendarParser.durationSeconds("P"))
        XCTAssertNil(ICalendarParser.durationSeconds("42"))
    }

    func testSimpleWeeklyRecurrenceIsModeled() throws {
        let event = try firstEvent([
            "DTSTART:20260106T170000Z",
            "RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,TH;COUNT=10",
        ])
        let rule = try XCTUnwrap(event.recurrence)
        XCTAssertEqual(rule.frequency, .weekly)
        XCTAssertEqual(rule.interval, 2)
        XCTAssertEqual(rule.count, 10)
        XCTAssertEqual(rule.byDay, [.tuesday, .thursday])
        XCTAssertEqual(event.recurrenceRaw, "FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,TH;COUNT=10")
    }

    // Rules beyond the bounded model must surface as raw-only: mapping
    // "third Friday monthly" to plain "monthly" would repeat on wrong days.
    func testComplexRecurrenceKeepsRawButNoRule() throws {
        let event = try firstEvent([
            "DTSTART:20260106T170000Z",
            "RRULE:FREQ=MONTHLY;BYDAY=3FR",
        ])
        XCTAssertNil(event.recurrence)
        XCTAssertEqual(event.recurrenceRaw, "FREQ=MONTHLY;BYDAY=3FR")
    }

    func testMultipleEvents() throws {
        let ics = wrap([
            "BEGIN:VEVENT",
            "DTSTART:20260101T090000Z",
            "SUMMARY:One",
            "END:VEVENT",
            "BEGIN:VEVENT",
            "DTSTART:20260102T090000Z",
            "SUMMARY:Two",
            "END:VEVENT",
        ])
        let calendar = ICalendarParser.parse(ics)
        XCTAssertEqual(calendar?.events.map(\.summary), ["One", "Two"])
    }

    func testNonCalendarPayloadReturnsNil() {
        XCTAssertNil(ICalendarParser.parse("This is just a text file.\r\nNothing to see."))
        XCTAssertNil(ICalendarParser.parse(Data([0xFF, 0xD8, 0xFF, 0xE0])))
    }

    func testTruncatedEventIsDropped() {
        let ics = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nSUMMARY:Cut off"
        XCTAssertEqual(ICalendarParser.parse(ics)?.events.count, 0)
    }

    func testAttachmentDetection() {
        XCTAssertTrue(ICalendar.isCalendarAttachment(mimeType: "text/calendar", filename: nil))
        XCTAssertTrue(ICalendar.isCalendarAttachment(mimeType: "TEXT/Calendar", filename: "x.bin"))
        XCTAssertTrue(ICalendar.isCalendarAttachment(mimeType: "application/octet-stream", filename: "invite.ICS"))
        XCTAssertFalse(ICalendar.isCalendarAttachment(mimeType: "application/pdf", filename: "invite.pdf"))
        XCTAssertFalse(ICalendar.isCalendarAttachment(mimeType: "application/octet-stream", filename: nil))
    }

    // Outlook-style TZID that the system database can't resolve: the time
    // degrades to floating (nil zone) instead of failing the parse.
    func testUnresolvableTZIDDegradesToFloating() throws {
        let event = try firstEvent([
            "DTSTART;TZID=Romance Standard Time:20260915T140000",
        ])
        let start = try XCTUnwrap(event.start)
        XCTAssertNil(start.timeZone)
        XCTAssertFalse(start.isDateOnly)
    }

    private func firstEvent(_ eventLines: [String]) throws -> ICalendarEvent {
        let ics = wrap(["BEGIN:VEVENT"] + eventLines + ["END:VEVENT"])
        let calendar = try XCTUnwrap(ICalendarParser.parse(ics))
        return try XCTUnwrap(calendar.events.first)
    }

    private func wrap(_ lines: [String]) -> String {
        (["BEGIN:VCALENDAR", "VERSION:2.0"] + lines + ["END:VCALENDAR"]).joined(separator: "\r\n")
    }
}
