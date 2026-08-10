import SwiftUI
import CabalmailKit
#if canImport(EventKitUI)
import EventKit
import EventKitUI

/// Calendar-invite sheet for `.ics` attachments (iOS / visionOS).
///
/// iOS gives third-party apps no system route into Calendar for `.ics`
/// files — Calendar ships no share extension and QuickLook's event preview
/// has no Add button (only Apple Mail and Safari get the import flow). So
/// the reader parses the invite itself (`ICalendarParser` in CabalmailKit)
/// and offers each event through `EKEventEditViewController`, prefilled.
/// That controller runs out-of-process since iOS 17, so no calendar
/// permission or usage-description string is needed. macOS doesn't use this
/// sheet: there `NSWorkspace.open` on the `.ics` triggers Calendar's own
/// import prompt.
struct CalendarInvite: Identifiable {
    let id = UUID()
    let calendar: ICalendar
}

struct CalendarEventSheet: View {
    let invite: CalendarInvite

    @Environment(\.dismiss) private var dismiss
    @State private var editingEvent: IndexedEvent?

    private struct IndexedEvent: Identifiable {
        let id: Int
        let event: ICalendarEvent
    }

    private var events: [IndexedEvent] {
        invite.calendar.events.enumerated().map { IndexedEvent(id: $0.offset, event: $0.element) }
    }

    var body: some View {
        NavigationStack {
            List(events) { indexed in
                eventSection(indexed)
            }
            .navigationTitle(events.count == 1 ? "Event" : "Events")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheet(item: $editingEvent) { indexed in
            EventEditView(event: indexed.event) { editingEvent = nil }
                .ignoresSafeArea()
        }
    }

    private func eventSection(_ indexed: IndexedEvent) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(indexed.event.summary ?? "(no title)")
                    .font(.headline)
                if isCancelled(indexed.event) {
                    Label("This event was cancelled", systemImage: "xmark.circle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                detailRows(indexed.event)
            }
            .padding(.vertical, 4)
            Button {
                editingEvent = indexed
            } label: {
                Label("Add to Calendar", systemImage: "calendar.badge.plus")
            }
            .accessibilityIdentifier("reader.addToCalendar.\(indexed.id)")
        }
    }

    @ViewBuilder
    private func detailRows(_ event: ICalendarEvent) -> some View {
        if let dateLine = Self.dateLine(for: event) {
            Text(dateLine)
                .font(.subheadline)
        }
        if let repeats = Self.recurrenceLine(for: event) {
            Label(repeats, systemImage: "repeat")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if let location = event.location, !location.isEmpty {
            Label(location, systemImage: "mappin.and.ellipse")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if let organizer = event.organizer {
            Label(organizer, systemImage: "person.crop.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if let description = event.description, !description.isEmpty {
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(6)
        }
    }

    private func isCancelled(_ event: ICalendarEvent) -> Bool {
        invite.calendar.method == "CANCEL" || event.status == "CANCELLED"
    }

    /// "Sep 15, 2026, 2:00–3:00 PM" for timed events, the bare date(s) for
    /// all-day ones. Rendered in the user's zone — matching what Calendar
    /// will show after the add.
    static func dateLine(for event: ICalendarEvent) -> String? {
        guard let start = event.start else { return nil }
        let startDate = start.resolved()
        if start.isDateOnly {
            // DTEND is exclusive for all-day events; step back a day so a
            // one-day event doesn't render as a two-day range.
            let endDate = event.end.map { $0.resolved().addingTimeInterval(-86_400) }
            guard let endDate, endDate > startDate else {
                return startDate.formatted(date: .complete, time: .omitted)
            }
            return (startDate..<endDate).formatted(date: .abbreviated, time: .omitted)
        }
        guard let end = event.end, end.date > start.date else {
            return startDate.formatted(date: .abbreviated, time: .shortened)
        }
        return (start.date..<end.date).formatted(date: .abbreviated, time: .shortened)
    }

    /// Human summary of the recurrence: the bounded rule when we have one,
    /// otherwise a generic marker so a complex RRULE isn't silently hidden.
    static func recurrenceLine(for event: ICalendarEvent) -> String? {
        guard event.recurrenceRaw != nil else { return nil }
        guard let rule = event.recurrence else {
            return "Repeats (add to Calendar to see the schedule; complex rules import without repeat)"
        }
        let unit: String
        switch rule.frequency {
        case .daily:   unit = rule.interval == 1 ? "day" : "days"
        case .weekly:  unit = rule.interval == 1 ? "week" : "weeks"
        case .monthly: unit = rule.interval == 1 ? "month" : "months"
        case .yearly:  unit = rule.interval == 1 ? "year" : "years"
        }
        var line = rule.interval == 1 ? "Repeats every \(unit)" : "Repeats every \(rule.interval) \(unit)"
        if let count = rule.count { line += ", \(count) times" }
        return line
    }
}

/// `EKEventEditViewController` bridge. A fresh in-memory `EKEventStore` backs
/// the prefilled event; the actual save happens in the out-of-process edit UI.
private struct EventEditView: UIViewControllerRepresentable {
    let event: ICalendarEvent
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let store = EKEventStore()
        let controller = EKEventEditViewController()
        controller.eventStore = store
        controller.event = CalendarEventMapper.makeEKEvent(from: event, store: store)
        controller.editViewDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: EKEventEditViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onDismiss: onDismiss) }

    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let onDismiss: () -> Void

        init(onDismiss: @escaping () -> Void) {
            self.onDismiss = onDismiss
        }

        func eventEditViewController(
            _ controller: EKEventEditViewController,
            didCompleteWith action: EKEventEditViewAction
        ) {
            onDismiss()
        }
    }
}

enum CalendarEventMapper {
    static func makeEKEvent(from event: ICalendarEvent, store: EKEventStore) -> EKEvent {
        let ekEvent = EKEvent(eventStore: store)
        ekEvent.title = event.summary ?? "New Event"
        ekEvent.location = event.location
        ekEvent.notes = event.description
        ekEvent.url = event.url
        if let start = event.start {
            if start.isDateOnly {
                ekEvent.isAllDay = true
                let startDate = start.resolved()
                ekEvent.startDate = startDate
                // DTEND is exclusive; EK wants an instant inside the last day.
                let exclusiveEnd = event.end?.resolved() ?? startDate.addingTimeInterval(86_400)
                ekEvent.endDate = max(startDate, exclusiveEnd.addingTimeInterval(-86_400))
            } else {
                ekEvent.startDate = start.date
                ekEvent.endDate = event.end?.date ?? start.date.addingTimeInterval(3_600)
                ekEvent.timeZone = start.timeZone
            }
        }
        if let rule = event.recurrence {
            ekEvent.addRecurrenceRule(recurrenceRule(from: rule))
        }
        return ekEvent
    }

    private static func recurrenceRule(from rule: ICalendarRecurrenceRule) -> EKRecurrenceRule {
        let end: EKRecurrenceEnd?
        if let count = rule.count {
            end = EKRecurrenceEnd(occurrenceCount: count)
        } else if let until = rule.until {
            end = EKRecurrenceEnd(end: until)
        } else {
            end = nil
        }
        let frequency: EKRecurrenceFrequency
        switch rule.frequency {
        case .daily:   frequency = .daily
        case .weekly:  frequency = .weekly
        case .monthly: frequency = .monthly
        case .yearly:  frequency = .yearly
        }
        let days = rule.byDay.map { EKRecurrenceDayOfWeek(weekday($0)) }
        return EKRecurrenceRule(
            recurrenceWith: frequency,
            interval: rule.interval,
            daysOfTheWeek: days.isEmpty ? nil : days,
            daysOfTheMonth: nil,
            monthsOfTheYear: nil,
            weeksOfTheYear: nil,
            daysOfTheYear: nil,
            setPositions: nil,
            end: end
        )
    }

    private static func weekday(_ day: ICalendarRecurrenceRule.Weekday) -> EKWeekday {
        switch day {
        case .sunday:    return .sunday
        case .monday:    return .monday
        case .tuesday:   return .tuesday
        case .wednesday: return .wednesday
        case .thursday:  return .thursday
        case .friday:    return .friday
        case .saturday:  return .saturday
        }
    }
}
#endif
