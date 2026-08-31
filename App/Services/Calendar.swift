import AppKit
import CoreLocation
import EventKit
import Foundation
import JSONSchema
import OSLog
import Ontology

private let log = Logger.service("calendar")

final class CalendarService: Service {
    private let eventStore = EKEventStore()

    static let shared = CalendarService()

    var isActivated: Bool {
        get async {
            return EKEventStore.authorizationStatus(for: .event) == .fullAccess
        }
    }

    func activate() async throws {
        try await eventStore.requestFullAccessToEvents()
    }

    private func error(_ code: Int, _ message: String) -> NSError {
        NSError(
            domain: "CalendarError",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    /// `Value.intValue` and `doubleValue` don't coerce between the two, so a
    /// JSON number arriving as `2` rather than `2.0` (or vice versa) would
    /// otherwise read as absent.
    private func intArgument(_ value: Value?) -> Int? {
        if let int = value?.intValue { return int }
        if let double = value?.doubleValue { return Int(double) }
        return nil
    }

    private func doubleArgument(_ value: Value?) -> Double? {
        if let double = value?.doubleValue { return double }
        if let int = value?.intValue { return Double(int) }
        return nil
    }

    /// Encode events for tool output, annotating each with its stable
    /// `identifier` and organizer information. Both are added at the `Value`
    /// layer because the remote Ontology `Event` model is left untouched — it
    /// has an `identifier` property but excludes it from its `CodingKeys`.
    private func encode(_ events: [EKEvent]) throws -> [Value] {
        let encoder = JSONEncoder()
        encoder.userInfo[Ontology.DateTime.timeZoneOverrideKey] = TimeZone.current
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let decoder = JSONDecoder()

        return try events.map { ekEvent -> Value in
            let data = try encoder.encode(Event(ekEvent))
            var value = try decoder.decode(Value.self, from: data)
            if case .object(var object) = value {
                if let identifier = ekEvent.eventIdentifier, !identifier.isEmpty {
                    object["identifier"] = .string(identifier)
                }
                object["organizedByMe"] = .bool(ekEvent.isOrganizedByCurrentUser)
                if let organizerName = ekEvent.organizerDisplayName {
                    object["organizer"] = .string(organizerName)
                }
                object["isRecurring"] = .bool(ekEvent.hasRecurrenceRules)
                // A named place carries an EKStructuredLocation with real
                // coordinates; `location` alone is just its display text.
                if let structuredLocation = ekEvent.structuredLocation {
                    if let geoLocation = structuredLocation.geoLocation {
                        object["latitude"] = .double(geoLocation.coordinate.latitude)
                        object["longitude"] = .double(geoLocation.coordinate.longitude)
                    }
                    if structuredLocation.radius > 0 {
                        object["radius"] = .double(structuredLocation.radius)
                    }
                }
                value = .object(object)
            }
            return value
        }
    }

    private func encode(_ event: EKEvent) throws -> Value {
        try encode([event])[0]
    }

    /// Build the alarms for an event from an `alarms` argument array.
    private func makeAlarms(from alarmConfigs: [Value]) -> [EKAlarm] {
        var alarms: [EKAlarm] = []

        for alarmConfig in alarmConfigs {
            guard case .object(let config) = alarmConfig else { continue }

            var alarm: EKAlarm?

            let alarmType = config["type"]?.stringValue ?? "relative"
            switch alarmType {
            case "relative":
                if let minutes = self.intArgument(config["minutes"]) {
                    alarm = EKAlarm(relativeOffset: TimeInterval(-minutes * 60))
                }

            case "absolute":
                if case .string(let datetimeStr) = config["datetime"] {
                    if ISO8601DateFormatter.isDateOnlyISO8601String(datetimeStr) {
                        log.error(
                            "Absolute alarm datetime must include time component: \(datetimeStr, privacy: .public)"
                        )
                    } else if let absoluteDate = ISO8601DateFormatter.lenientDate(
                        fromISO8601String: datetimeStr
                    ) {
                        alarm = EKAlarm(absoluteDate: absoluteDate)
                    }
                }

            case "proximity":
                if case .string(let locationTitle) = config["locationTitle"],
                    let latitude = self.doubleArgument(config["latitude"]),
                    let longitude = self.doubleArgument(config["longitude"])
                {
                    alarm = EKAlarm()

                    // Create structured location
                    let structuredLocation = EKStructuredLocation(title: locationTitle)
                    structuredLocation.geoLocation = CLLocation(
                        latitude: latitude,
                        longitude: longitude
                    )

                    if let radius = self.doubleArgument(config["radius"]) {
                        structuredLocation.radius = radius
                    }

                    // Set proximity type
                    let proximityType = config["proximity"]?.stringValue ?? "enter"
                    let proximity: EKAlarmProximity =
                        proximityType == "enter" ? .enter : .leave
                    alarm?.proximity = proximity
                    alarm?.structuredLocation = structuredLocation
                }

            default:
                log.error(
                    "Unexpected alarm type encountered: \(alarmType, privacy: .public)"
                )
                continue
            }

            guard let alarm = alarm else { continue }

            if case .string(let soundName) = config["sound"],
                Sound(rawValue: soundName) != nil
            {
                alarm.soundName = soundName
            }

            if case .string(let email) = config["emailAddress"], !email.isEmpty {
                alarm.emailAddress = email
            }

            alarms.append(alarm)
        }

        return alarms
    }

    /// Build an `EKRecurrenceRule` from a `recurrence` argument object.
    ///
    /// EventKit raises an Objective-C exception — which Swift cannot catch, so
    /// it would take the whole app down — when a rule combines a frequency with
    /// a "by" component it doesn't support, such as days-of-the-month on a
    /// weekly series. Every such constraint is therefore checked up front.
    private func makeRecurrenceRule(from recurrence: [String: Value]) throws -> EKRecurrenceRule {
        guard let frequencyName = recurrence["frequency"]?.stringValue,
            let frequency = EKRecurrenceFrequency(validating: frequencyName)
        else {
            let supported = EKRecurrenceFrequency.allCases.map { $0.stringValue }
                .joined(separator: ", ")
            throw self.error(9, "Recurrence requires a \"frequency\" of: \(supported)")
        }

        let interval = self.intArgument(recurrence["interval"]) ?? 1
        guard interval >= 1 else {
            throw self.error(9, "Recurrence \"interval\" must be 1 or greater")
        }

        var daysOfTheWeek: [EKRecurrenceDayOfWeek]?
        if case .array(let days) = recurrence["daysOfTheWeek"], !days.isEmpty {
            guard frequency != .daily else {
                throw self.error(9, "\"daysOfTheWeek\" is not supported for a daily recurrence")
            }
            daysOfTheWeek = try days.map { entry in
                let dayName: String
                var weekNumber = 0

                if let name = entry.stringValue {
                    dayName = name
                } else if case .object(let object) = entry,
                    let name = object["day"]?.stringValue
                {
                    dayName = name
                    weekNumber = self.intArgument(object["weekNumber"]) ?? 0
                } else {
                    throw self.error(
                        9,
                        "Each \"daysOfTheWeek\" entry must be a weekday name or an object with a \"day\""
                    )
                }

                guard let weekday = EKWeekday(validating: dayName) else {
                    throw self.error(9, "Unknown weekday in \"daysOfTheWeek\": \(dayName)")
                }
                guard weekNumber == 0 || frequency == .monthly || frequency == .yearly else {
                    throw self.error(
                        9,
                        "\"weekNumber\" is only supported for a monthly or yearly recurrence"
                    )
                }
                guard (-53 ... 53).contains(weekNumber) else {
                    throw self.error(9, "\"weekNumber\" must be between -53 and 53")
                }

                return EKRecurrenceDayOfWeek(dayOfTheWeek: weekday, weekNumber: weekNumber)
            }
        }

        var daysOfTheMonth: [NSNumber]?
        if case .array(let days) = recurrence["daysOfTheMonth"], !days.isEmpty {
            guard frequency == .monthly else {
                throw self.error(
                    9,
                    "\"daysOfTheMonth\" is only supported for a monthly recurrence"
                )
            }
            daysOfTheMonth = try days.map { entry in
                guard let day = self.intArgument(entry), day != 0, (-31 ... 31).contains(day) else {
                    throw self.error(
                        9,
                        "\"daysOfTheMonth\" entries must be between -31 and 31, excluding 0"
                    )
                }
                return NSNumber(value: day)
            }
        }

        var monthsOfTheYear: [NSNumber]?
        if case .array(let months) = recurrence["monthsOfTheYear"], !months.isEmpty {
            guard frequency == .yearly else {
                throw self.error(
                    9,
                    "\"monthsOfTheYear\" is only supported for a yearly recurrence"
                )
            }
            monthsOfTheYear = try months.map { entry in
                guard let month = self.intArgument(entry), (1 ... 12).contains(month) else {
                    throw self.error(9, "\"monthsOfTheYear\" entries must be between 1 and 12")
                }
                return NSNumber(value: month)
            }
        }

        var setPositions: [NSNumber]?
        if case .array(let positions) = recurrence["setPositions"], !positions.isEmpty {
            guard daysOfTheWeek != nil || daysOfTheMonth != nil || monthsOfTheYear != nil else {
                throw self.error(
                    9,
                    "\"setPositions\" requires \"daysOfTheWeek\", \"daysOfTheMonth\" or \"monthsOfTheYear\""
                )
            }
            setPositions = try positions.map { entry in
                guard let position = self.intArgument(entry), position != 0,
                    (-366 ... 366).contains(position)
                else {
                    throw self.error(
                        9,
                        "\"setPositions\" entries must be between -366 and 366, excluding 0"
                    )
                }
                return NSNumber(value: position)
            }
        }

        let untilString = recurrence["until"]?.stringValue
        let occurrenceCount = self.intArgument(recurrence["occurrenceCount"])
        guard untilString == nil || occurrenceCount == nil else {
            throw self.error(9, "Provide either \"until\" or \"occurrenceCount\", not both")
        }

        var end: EKRecurrenceEnd?
        if let untilString {
            guard
                let parsed = ISO8601DateFormatter.parsedLenientISO8601Date(
                    fromISO8601String: untilString
                )
            else {
                throw self.error(9, "Invalid \"until\" date. Expected ISO 8601 format.")
            }
            end = EKRecurrenceEnd(
                end: Calendar.current.normalizedEndDate(
                    from: parsed.date,
                    isDateOnly: parsed.isDateOnly
                )
            )
        } else if let occurrenceCount {
            guard occurrenceCount >= 1 else {
                throw self.error(9, "\"occurrenceCount\" must be 1 or greater")
            }
            end = EKRecurrenceEnd(occurrenceCount: occurrenceCount)
        }

        return EKRecurrenceRule(
            recurrenceWith: frequency,
            interval: interval,
            daysOfTheWeek: daysOfTheWeek,
            daysOfTheMonth: daysOfTheMonth,
            monthsOfTheYear: monthsOfTheYear,
            weeksOfTheYear: nil,
            daysOfTheYear: nil,
            setPositions: setPositions,
            end: end
        )
    }

    /// The occurrence of a recurring `event` that starts at `start`, if any.
    /// Every occurrence of a series shares one `eventIdentifier`, so a date is
    /// the only way to single one out.
    private func occurrence(of event: EKEvent, startingAt start: Date) -> EKEvent? {
        let calendar = Calendar.current
        guard let windowStart = calendar.date(byAdding: .day, value: -1, to: start),
            let windowEnd = calendar.date(byAdding: .day, value: 1, to: start)
        else { return nil }

        var calendars: [EKCalendar]?
        if let eventCalendar: EKCalendar = event.calendar {
            calendars = [eventCalendar]
        }

        let predicate = self.eventStore.predicateForEvents(
            withStart: windowStart,
            end: windowEnd,
            calendars: calendars
        )

        return self.eventStore.events(matching: predicate).first {
            $0.eventIdentifier == event.eventIdentifier
                && calendar.isDate($0.startDate, equalTo: start, toGranularity: .minute)
        }
    }

    /// Find the single event an update or delete should act on.
    ///
    /// Prefers the stable `identifier` returned by events_fetch; otherwise
    /// matches an exact, case-insensitive title inside a search window. Throws
    /// if nothing matches, or if a title matches more than one event.
    private func locateEvent(from arguments: [String: Value]) throws -> EKEvent {
        let calendar = Calendar.current

        var occurrenceStart: Date?
        if let value = arguments["occurrenceStart"]?.stringValue,
            let parsed = ISO8601DateFormatter.parsedLenientISO8601Date(fromISO8601String: value)
        {
            occurrenceStart = calendar.normalizedStartDate(
                from: parsed.date,
                isDateOnly: parsed.isDateOnly
            )
        }

        if let identifier = arguments["identifier"]?.stringValue, !identifier.isEmpty {
            guard let event = self.eventStore.event(withIdentifier: identifier) else {
                throw self.error(5, "No event found with identifier: \(identifier)")
            }
            guard let occurrenceStart, event.hasRecurrenceRules else { return event }
            guard let occurrence = self.occurrence(of: event, startingAt: occurrenceStart) else {
                throw self.error(
                    7,
                    "No occurrence of \"\(event.title ?? "")\" starts at the given \"occurrenceStart\""
                )
            }
            return occurrence
        }

        guard let title = arguments["title"]?.stringValue, !title.isEmpty else {
            throw self.error(6, "Provide an \"identifier\" or a \"title\" to locate the event")
        }

        // Default to the coming year, narrowed to a single day when the caller
        // pinned an occurrence.
        var windowStart =
            occurrenceStart.flatMap {
                calendar.date(byAdding: .day, value: -1, to: $0)
            } ?? Date()
        if let value = arguments["searchStart"]?.stringValue,
            let parsed = ISO8601DateFormatter.parsedLenientISO8601Date(fromISO8601String: value)
        {
            windowStart = calendar.normalizedStartDate(
                from: parsed.date,
                isDateOnly: parsed.isDateOnly
            )
        }

        var windowEnd =
            occurrenceStart.flatMap { calendar.date(byAdding: .day, value: 1, to: $0) }
            ?? calendar.date(byAdding: .year, value: 1, to: windowStart)
            ?? windowStart
        if let value = arguments["searchEnd"]?.stringValue,
            let parsed = ISO8601DateFormatter.parsedLenientISO8601Date(fromISO8601String: value)
        {
            windowEnd = calendar.normalizedEndDate(
                from: parsed.date,
                isDateOnly: parsed.isDateOnly
            )
        }

        var calendars = self.eventStore.calendars(for: .event)
        if let calendarName = arguments["searchCalendar"]?.stringValue, !calendarName.isEmpty {
            calendars = calendars.filter { $0.title.lowercased() == calendarName.lowercased() }
        }

        let predicate = self.eventStore.predicateForEvents(
            withStart: windowStart,
            end: windowEnd,
            calendars: calendars
        )

        var matches = self.eventStore.events(matching: predicate).filter {
            $0.title?.lowercased() == title.lowercased()
        }
        if let occurrenceStart {
            matches = matches.filter {
                calendar.isDate($0.startDate, equalTo: occurrenceStart, toGranularity: .minute)
            }
        }

        let formatter = ISO8601DateFormatter()
        guard let first = matches.first else {
            throw self.error(
                7,
                "No event titled \"\(title)\" found between \(formatter.string(from: windowStart)) and \(formatter.string(from: windowEnd)); widen the window with \"searchStart\"/\"searchEnd\""
            )
        }
        guard matches.count == 1 else {
            throw self.error(
                8,
                "Found \(matches.count) events titled \"\(title)\"; pass an \"identifier\" (from events_fetch), an \"occurrenceStart\", or a narrower \"searchStart\"/\"searchEnd\" window to choose one"
            )
        }
        return first
    }

    /// Apply the `location` arguments. Coordinates are kept in an
    /// `EKStructuredLocation` so the event gets a real map pin rather than text
    /// a client would have to geocode again.
    ///
    /// These are flat sibling arguments rather than one nested object because a
    /// client that cannot express a composite schema will stringify an object
    /// argument in transit, silently storing raw JSON as the location text.
    private func applyLocation(from arguments: [String: Value], to event: EKEvent) throws {
        let text = arguments["location"]?.stringValue
        let latitude = self.doubleArgument(arguments["locationLatitude"])
        let longitude = self.doubleArgument(arguments["locationLongitude"])

        guard (latitude == nil) == (longitude == nil) else {
            throw self.error(
                10,
                "\"locationLatitude\" and \"locationLongitude\" must be provided together"
            )
        }

        // An explicit null or an empty string clears the location outright.
        if arguments["location"]?.isNull == true || (text?.isEmpty == true && latitude == nil) {
            event.structuredLocation = nil
            event.location = nil
            return
        }

        guard latitude != nil || text != nil else { return }

        guard let latitude, let longitude else {
            event.location = text
            return
        }
        guard (-90 ... 90).contains(latitude), (-180 ... 180).contains(longitude) else {
            throw self.error(
                10,
                "\"locationLatitude\" must be between -90 and 90 and \"locationLongitude\" between -180 and 180"
            )
        }

        // A structured location needs a title; fall back to what the event
        // already shows when only coordinates are being changed.
        let title = text ?? event.location ?? ""
        guard !title.isEmpty else {
            throw self.error(10, "Coordinates need a \"location\" naming the place")
        }

        let structuredLocation = EKStructuredLocation(title: title)
        structuredLocation.geoLocation = CLLocation(latitude: latitude, longitude: longitude)
        if let radius = self.doubleArgument(arguments["locationRadius"]), radius > 0 {
            structuredLocation.radius = radius
        }
        event.structuredLocation = structuredLocation
    }

    /// Schema for the `alarms` argument, shared by events_create and
    /// events_update.
    private static func alarmsSchema(description: String) -> JSONSchema {
        .array(
            description: description,
            items: .anyOf(
                [
                    // Relative alarm (minutes before event)
                    .object(
                        properties: [
                            "type": .string(
                                const: "relative",
                            ),
                            "minutes": .integer(
                                description:
                                    "Minutes offset from event start (negative for before, positive for after)"
                            ),
                            "sound": .string(
                                description: "Sound name to play when alarm triggers",
                                enum: Sound.allCases.map { .string($0.rawValue) }
                            ),
                            "emailAddress": .string(
                                description: "Email address to send notification to"
                            ),
                        ],
                        required: ["minutes"],
                        additionalProperties: false
                    ),
                    // Absolute alarm (specific date/time)
                    .object(
                        properties: [
                            "type": .string(
                                const: "absolute",
                            ),
                            "datetime": .string(
                                description:
                                    "Alarm date/time. If timezone is omitted, local time is assumed. Date-only uses local midnight.",
                                format: .dateTime
                            ),
                            "sound": .string(
                                description: "Sound name to play when alarm triggers",
                                enum: Sound.allCases.map { .string($0.rawValue) }
                            ),
                            "emailAddress": .string(
                                description: "Email address to send notification to"
                            ),
                        ],
                        required: ["datetime"],
                        additionalProperties: false
                    ),
                    // Proximity alarm (location-based)
                    .object(
                        properties: [
                            "type": .string(
                                const: "proximity",
                            ),
                            "proximity": .string(
                                description: "Proximity trigger type",
                                default: "enter",
                                enum: ["enter", "leave"]
                            ),
                            "locationTitle": .string(),
                            "latitude": .number(),
                            "longitude": .number(),
                            "radius": .number(
                                description: "Radius in meters",
                                default: .int(200)
                            ),
                            "sound": .string(
                                description: "Sound name to play when alarm triggers",
                                enum: Sound.allCases.map { .string($0.rawValue) }
                            ),
                            "emailAddress": .string(
                                description: "Email address to send notification to"
                            ),
                        ],
                        required: ["locationTitle", "latitude", "longitude"],
                        additionalProperties: false
                    ),
                ]
            )
        )
    }

    /// Schema for the `recurrence` argument, shared by events_create and
    /// events_update.
    private static let recurrenceSchema: JSONSchema = .object(
        description:
            "Recurrence rule that makes this a repeating event. Omit for a one-off event.",
        properties: [
            "frequency": .string(
                description: "How often the event repeats",
                enum: EKRecurrenceFrequency.allCases.map { .string($0.stringValue) }
            ),
            "interval": .integer(
                description:
                    "Repeat every N periods of \"frequency\"; e.g. frequency \"weekly\" with interval 2 repeats every other week",
                default: .int(1),
                minimum: 1
            ),
            "daysOfTheWeek": .array(
                description:
                    "Days the event repeats on; weekly, monthly and yearly only. Each entry is a weekday name, or an object with \"day\" plus a \"weekNumber\" for ordinals such as the third Thursday (monthly and yearly only).",
                items: .anyOf([
                    .string(enum: EKWeekday.allCases.map { .string($0.stringValue) }),
                    .object(
                        properties: [
                            "day": .string(
                                enum: EKWeekday.allCases.map { .string($0.stringValue) }
                            ),
                            "weekNumber": .integer(
                                description:
                                    "Ordinal week; negative counts from the end, so -1 is the last. 0 means every matching weekday.",
                                default: .int(0),
                                minimum: -53,
                                maximum: 53
                            ),
                        ],
                        required: ["day"],
                        additionalProperties: false
                    ),
                ])
            ),
            "daysOfTheMonth": .array(
                description:
                    "Days of the month the event repeats on; monthly only. Negative counts from the end, so -1 is the last day.",
                items: .integer(minimum: -31, maximum: 31)
            ),
            "monthsOfTheYear": .array(
                description: "Months the event repeats in (1-12); yearly only.",
                items: .integer(minimum: 1, maximum: 12)
            ),
            "setPositions": .array(
                description:
                    "Pick particular occurrences out of the matches above, e.g. -1 for the last one. Requires \"daysOfTheWeek\", \"daysOfTheMonth\" or \"monthsOfTheYear\".",
                items: .integer(minimum: -366, maximum: 366)
            ),
            "until": .string(
                description:
                    "Date the recurrence stops repeating, inclusive. Mutually exclusive with \"occurrenceCount\"; omit both to repeat indefinitely.",
                format: .dateTime
            ),
            "occurrenceCount": .integer(
                description:
                    "Total number of occurrences. Mutually exclusive with \"until\".",
                minimum: 1
            ),
        ],
        required: ["frequency"],
        additionalProperties: false
    )

    var tools: [Tool] {
        Tool(
            name: "calendars_list",
            description: "List available calendars",
            inputSchema: .object(
                properties: [:],
                additionalProperties: false
            ),
            annotations: .init(
                title: "List Calendars",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
                log.error("Calendar access not authorized")
                throw NSError(
                    domain: "CalendarError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Calendar access not authorized"]
                )
            }

            let calendars = self.eventStore.calendars(for: .event)

            return calendars.map { calendar in
                Value.object([
                    "title": .string(calendar.title),
                    "source": .string(calendar.source.title),
                    "color": .string(calendar.color.accessibilityName),
                    "isEditable": .bool(calendar.allowsContentModifications),
                    "isSubscribed": .bool(calendar.isSubscribed),
                ])
            }
        }

        Tool(
            name: "events_fetch",
            description: "Get events from the calendar with flexible filtering options",
            inputSchema: .object(
                properties: [
                    "start": .string(
                        description:
                            "Start date/time (defaults to now; if end is date-only and start is omitted, uses end's local midnight). If timezone is omitted, local time is assumed.",
                        format: .dateTime
                    ),
                    "end": .string(
                        description:
                            "End date/time (defaults to one week from start; one day if start is date-only). If timezone is omitted, local time is assumed.",
                        format: .dateTime
                    ),
                    "calendars": .array(
                        description:
                            "Names of calendars to fetch from; if empty, fetches from all calendars",
                        items: .string(),
                    ),
                    "query": .string(
                        description: "Text to search for in event titles and locations"
                    ),
                    "includeAllDay": .boolean(
                        default: true
                    ),
                    "status": .string(
                        description: "Filter by event status",
                        enum: ["none", "tentative", "confirmed", "canceled"]
                    ),
                    "availability": .string(
                        description: "Filter by availability status",
                        enum: EKEventAvailability.allCases.map { .string($0.stringValue) }
                    ),
                    "hasAlarms": .boolean(),
                    "isRecurring": .boolean(),
                    "organizer": .string(
                        description:
                            "Filter by who organized the event: 'me' for events you created or organize (including personal events with no other participants, birthdays, and subscribed holidays), 'others' for events someone else invited you to (e.g. a colleague's shared vacation/leave). Omit to include both.",
                        enum: ["me", "others"]
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Fetch Events",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
                log.error("Calendar access not authorized")
                throw NSError(
                    domain: "CalendarError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Calendar access not authorized"]
                )
            }

            // Filter calendars based on provided names
            var calendars = self.eventStore.calendars(for: .event)
            if case .array(let calendarNames) = arguments["calendars"],
                !calendarNames.isEmpty
            {
                let requestedNames = Set(calendarNames.compactMap { $0.stringValue?.lowercased() })
                calendars = calendars.filter { requestedNames.contains($0.title.lowercased()) }
            }

            // Parse dates and set defaults
            let now = Date()
            let calendar = Calendar.current
            var startDate = now
            var endDate = calendar.date(byAdding: .weekOfYear, value: 1, to: now)!
            var hasStart = false
            var hasEnd = false
            var startIsDateOnly = false
            var endIsDateOnly = false

            if case .string(let start) = arguments["start"],
                let parsedStart = ISO8601DateFormatter.parsedLenientISO8601Date(
                    fromISO8601String: start
                )
            {
                hasStart = true
                startDate = parsedStart.date
                startIsDateOnly = parsedStart.isDateOnly
            }

            if case .string(let end) = arguments["end"],
                let parsedEnd = ISO8601DateFormatter.parsedLenientISO8601Date(
                    fromISO8601String: end
                )
            {
                hasEnd = true
                endDate = parsedEnd.date
                endIsDateOnly = parsedEnd.isDateOnly
            }

            if !hasStart, endIsDateOnly {
                startDate = endDate
                startIsDateOnly = true
            }

            startDate = calendar.normalizedStartDate(from: startDate, isDateOnly: startIsDateOnly)

            if endIsDateOnly {
                endDate = calendar.normalizedEndDate(from: endDate, isDateOnly: true)
            } else if !hasEnd {
                if startIsDateOnly {
                    endDate = calendar.normalizedEndDate(from: startDate, isDateOnly: true)
                } else if let nextWeek = calendar.date(
                    byAdding: .weekOfYear,
                    value: 1,
                    to: startDate
                ) {
                    endDate = nextWeek
                }
            }

            // Create base predicate for date range and calendars
            let predicate = self.eventStore.predicateForEvents(
                withStart: startDate,
                end: endDate,
                calendars: calendars
            )

            // Fetch events
            var events = self.eventStore.events(matching: predicate)

            // Apply additional filters
            if case .bool(let includeAllDay) = arguments["includeAllDay"],
                !includeAllDay
            {
                events = events.filter { !$0.isAllDay }
            }

            if case .string(let searchText) = arguments["query"],
                !searchText.isEmpty
            {
                events = events.filter {
                    ($0.title?.localizedCaseInsensitiveContains(searchText) == true)
                        || ($0.location?.localizedCaseInsensitiveContains(searchText) == true)
                }
            }

            if case .string(let status) = arguments["status"] {
                let statusValue = EKEventStatus(status)
                events = events.filter { $0.status == statusValue }
            }

            if case .string(let availability) = arguments["availability"] {
                let availabilityValue = EKEventAvailability(availability)
                events = events.filter { $0.availability == availabilityValue }
            }

            if case .bool(let hasAlarms) = arguments["hasAlarms"] {
                events = events.filter { ($0.hasAlarms) == hasAlarms }
            }

            if case .bool(let isRecurring) = arguments["isRecurring"] {
                events = events.filter { ($0.hasRecurrenceRules) == isRecurring }
            }

            if case .string(let organizer) = arguments["organizer"] {
                switch organizer {
                case "me":
                    events = events.filter { $0.isOrganizedByCurrentUser }
                case "others":
                    events = events.filter { !$0.isOrganizedByCurrentUser }
                default:
                    break
                }
            }

            // Each event is annotated with its identifier and organizer, so callers
            // can address it later and tell events they own from ones they were
            // invited to.
            return try self.encode(events)
        }
        Tool(
            name: "events_create",
            description:
                "Create a new calendar event with specified properties, optionally repeating on a recurrence rule (e.g. every Monday until a given date)",
            inputSchema: .object(
                properties: [
                    "title": .string(),
                    "start": .string(
                        description:
                            "Start date/time for the event. If timezone is omitted, local time is assumed. Date-only uses local midnight.",
                        format: .dateTime
                    ),
                    "end": .string(
                        description:
                            "End date/time for the event. If timezone is omitted, local time is assumed. Date-only uses local midnight.",
                        format: .dateTime
                    ),
                    "calendar": .string(
                        description: "Calendar to use (uses default if not specified)"
                    ),
                    "location": .string(
                        description:
                            "Display text for the place, e.g. \"Sportcube\\nWaterleestvoetweg 12, 1980 Eppegem\". Pass an empty string to clear the location."
                    ),
                    "locationLatitude": .number(
                        description:
                            "Latitude of the location; give together with locationLongitude to store a real map pin instead of plain text",
                        minimum: -90,
                        maximum: 90
                    ),
                    "locationLongitude": .number(
                        description:
                            "Longitude of the location; give together with locationLatitude",
                        minimum: -180,
                        maximum: 180
                    ),
                    "locationRadius": .number(
                        description: "Geofence radius in meters for the location",
                        minimum: 0
                    ),
                    "notes": .string(),
                    "url": .string(
                        format: .uri
                    ),
                    "isAllDay": .boolean(
                        default: false
                    ),
                    "availability": .string(
                        description: "Availability status",
                        default: .string(EKEventAvailability.busy.stringValue),
                        enum: EKEventAvailability.allCases.map { .string($0.stringValue) }
                    ),
                    "alarms": CalendarService.alarmsSchema(
                        description: "Alarm configurations for the event"
                    ),
                    "hasAlarms": .boolean(),
                    "recurrence": CalendarService.recurrenceSchema,
                ],
                required: ["title", "start", "end"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Create Event",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.activate()

            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
                log.error("Calendar access not authorized")
                throw NSError(
                    domain: "CalendarError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Calendar access not authorized"]
                )
            }

            // Create new event
            let event = EKEvent(eventStore: self.eventStore)

            // Set required properties
            guard case .string(let title) = arguments["title"] else {
                throw NSError(
                    domain: "CalendarError",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Event title is required"]
                )
            }
            event.title = title

            // Parse dates
            guard case .string(let startDateStr) = arguments["start"],
                let parsedStart = ISO8601DateFormatter.parsedLenientISO8601Date(
                    fromISO8601String: startDateStr
                ),
                case .string(let endDateStr) = arguments["end"],
                let parsedEnd = ISO8601DateFormatter.parsedLenientISO8601Date(
                    fromISO8601String: endDateStr
                )
            else {
                throw NSError(
                    domain: "CalendarError",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Invalid start or end date format. Expected ISO 8601 format."
                    ]
                )
            }

            let calendar = Calendar.current
            let startDate = calendar.normalizedStartDate(
                from: parsedStart.date,
                isDateOnly: parsedStart.isDateOnly
            )
            let endDate = calendar.normalizedStartDate(
                from: parsedEnd.date,
                isDateOnly: parsedEnd.isDateOnly
            )

            // For all-day events, ensure we use local midnight
            if case .bool(true) = arguments["isAllDay"] {
                var startComponents = calendar.dateComponents(
                    [.year, .month, .day],
                    from: startDate
                )
                startComponents.hour = 0
                startComponents.minute = 0
                startComponents.second = 0

                var endComponents = calendar.dateComponents([.year, .month, .day], from: endDate)
                endComponents.hour = 23
                endComponents.minute = 59
                endComponents.second = 59

                event.startDate = calendar.date(from: startComponents)!
                event.endDate = calendar.date(from: endComponents)!
                event.isAllDay = true
            } else {
                event.startDate = startDate
                event.endDate = endDate
            }

            // Set calendar
            var targetCalendar = self.eventStore.defaultCalendarForNewEvents
            if case .string(let calendarName) = arguments["calendar"] {
                if let matchingCalendar = self.eventStore.calendars(for: .event)
                    .first(where: { $0.title.lowercased() == calendarName.lowercased() })
                {
                    targetCalendar = matchingCalendar
                }
            }
            event.calendar = targetCalendar

            // Set optional properties
            try self.applyLocation(from: arguments, to: event)

            if case .string(let notes) = arguments["notes"] {
                event.notes = notes
            }

            if case .string(let urlString) = arguments["url"],
                let url = URL(string: urlString)
            {
                event.url = url
            }

            if case .string(let availability) = arguments["availability"] {
                event.availability = EKEventAvailability(availability)
            }

            // Set alarms
            if case .array(let alarmConfigs) = arguments["alarms"] {
                event.alarms = self.makeAlarms(from: alarmConfigs)
            }

            // Set recurrence rule
            var isRecurring = false
            if case .object(let recurrence) = arguments["recurrence"] {
                event.recurrenceRules = [try self.makeRecurrenceRule(from: recurrence)]
                isRecurring = true
            }

            // A new series is saved as future events so the recurrence rule
            // applies to the whole series rather than just its first occurrence.
            try self.eventStore.save(event, span: isRecurring ? .futureEvents : .thisEvent, commit: true)

            return try self.encode(event)
        }

        Tool(
            name: "events_update",
            description:
                "Update an existing calendar event. Locate it by \"identifier\" (from events_fetch, recommended) or by \"title\". Only provide the properties you want to change; omitted properties are left unchanged. When locating by identifier, passing \"title\" renames the event. Set \"clearRecurrence\" to true to turn a repeating event into a one-off.",
            inputSchema: .object(
                properties: [
                    "identifier": .string(
                        description:
                            "Stable identifier of the event to update (from events_fetch). Preferred over title."
                    ),
                    "title": .string(
                        description:
                            "If \"identifier\" is omitted, the exact title used to locate the event. If \"identifier\" is provided, the new title to rename it to."
                    ),
                    "occurrenceStart": .string(
                        description:
                            "Start date/time of the specific occurrence to act on. Every occurrence of a repeating event shares one identifier, so this is how you single one out.",
                        format: .dateTime
                    ),
                    "searchStart": .string(
                        description:
                            "Start of the window searched when locating by title (defaults to now).",
                        format: .dateTime
                    ),
                    "searchEnd": .string(
                        description:
                            "End of the window searched when locating by title (defaults to one year after searchStart).",
                        format: .dateTime
                    ),
                    "searchCalendar": .string(
                        description: "Restrict a title match to this calendar"
                    ),
                    "start": .string(
                        description:
                            "New start date/time. If timezone is omitted, local time is assumed. Date-only uses local midnight.",
                        format: .dateTime
                    ),
                    "end": .string(
                        description:
                            "New end date/time. If timezone is omitted, local time is assumed. Date-only uses local midnight.",
                        format: .dateTime
                    ),
                    "calendar": .string(
                        description: "Move the event to this calendar"
                    ),
                    "location": .string(
                        description:
                            "Display text for the place, e.g. \"Sportcube\\nWaterleestvoetweg 12, 1980 Eppegem\". Pass an empty string to clear the location."
                    ),
                    "locationLatitude": .number(
                        description:
                            "Latitude of the location; give together with locationLongitude to store a real map pin instead of plain text",
                        minimum: -90,
                        maximum: 90
                    ),
                    "locationLongitude": .number(
                        description:
                            "Longitude of the location; give together with locationLatitude",
                        minimum: -180,
                        maximum: 180
                    ),
                    "locationRadius": .number(
                        description: "Geofence radius in meters for the location",
                        minimum: 0
                    ),
                    "notes": .string(),
                    "url": .string(
                        format: .uri
                    ),
                    "isAllDay": .boolean(),
                    "availability": .string(
                        description: "Availability status",
                        enum: EKEventAvailability.allCases.map { .string($0.stringValue) }
                    ),
                    "alarms": CalendarService.alarmsSchema(
                        description:
                            "Replace the event's alarms with these. Pass an empty array to remove all alarms."
                    ),
                    "recurrence": CalendarService.recurrenceSchema,
                    "clearRecurrence": .boolean(
                        description:
                            "Remove the recurrence rule, turning a repeating event into a one-off"
                    ),
                    "span": .string(
                        description:
                            "For a repeating event, whether the change applies only to the located occurrence or to it and all later ones. Ignored for one-off events.",
                        default: .string("thisEvent"),
                        enum: [.string("thisEvent"), .string("futureEvents")]
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Update Event",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.activate()

            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
                log.error("Calendar access not authorized")
                throw NSError(
                    domain: "CalendarError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Calendar access not authorized"]
                )
            }

            let locatedByIdentifier = !(arguments["identifier"]?.stringValue ?? "").isEmpty
            let event = try self.locateEvent(from: arguments)

            // When located by identifier, a title argument renames the event
            if locatedByIdentifier, let newTitle = arguments["title"]?.stringValue,
                !newTitle.isEmpty
            {
                event.title = newTitle
            }

            let calendar = Calendar.current

            // isAllDay is resolved before the dates, since it decides how they
            // are normalized.
            var isAllDay = event.isAllDay
            if case .bool(let allDay) = arguments["isAllDay"] {
                isAllDay = allDay
            }

            var startDate: Date = event.startDate
            var endDate: Date = event.endDate

            if case .string(let startDateStr) = arguments["start"] {
                guard
                    let parsed = ISO8601DateFormatter.parsedLenientISO8601Date(
                        fromISO8601String: startDateStr
                    )
                else {
                    throw self.error(2, "Invalid start date format. Expected ISO 8601 format.")
                }
                startDate = calendar.normalizedStartDate(
                    from: parsed.date,
                    isDateOnly: parsed.isDateOnly
                )
            }

            if case .string(let endDateStr) = arguments["end"] {
                guard
                    let parsed = ISO8601DateFormatter.parsedLenientISO8601Date(
                        fromISO8601String: endDateStr
                    )
                else {
                    throw self.error(2, "Invalid end date format. Expected ISO 8601 format.")
                }
                endDate = calendar.normalizedStartDate(
                    from: parsed.date,
                    isDateOnly: parsed.isDateOnly
                )
            }

            if isAllDay {
                var startComponents = calendar.dateComponents(
                    [.year, .month, .day],
                    from: startDate
                )
                startComponents.hour = 0
                startComponents.minute = 0
                startComponents.second = 0

                var endComponents = calendar.dateComponents([.year, .month, .day], from: endDate)
                endComponents.hour = 23
                endComponents.minute = 59
                endComponents.second = 59

                event.startDate = calendar.date(from: startComponents)!
                event.endDate = calendar.date(from: endComponents)!
            } else {
                event.startDate = startDate
                event.endDate = endDate
            }
            event.isAllDay = isAllDay

            guard event.endDate >= event.startDate else {
                throw self.error(2, "Event end date must not be before its start date")
            }

            // Move to another calendar
            if case .string(let calendarName) = arguments["calendar"] {
                guard
                    let matchingCalendar = self.eventStore.calendars(for: .event)
                        .first(where: { $0.title.lowercased() == calendarName.lowercased() })
                else {
                    throw self.error(2, "No calendar named: \(calendarName)")
                }
                event.calendar = matchingCalendar
            }

            try self.applyLocation(from: arguments, to: event)

            if case .string(let notes) = arguments["notes"] {
                event.notes = notes
            }

            if case .string(let urlString) = arguments["url"] {
                event.url = URL(string: urlString)
            }

            if case .string(let availability) = arguments["availability"] {
                event.availability = EKEventAvailability(availability)
            }

            if case .array(let alarmConfigs) = arguments["alarms"] {
                event.alarms = self.makeAlarms(from: alarmConfigs)
            }

            // An explicit null clears the recurrence, turning a series into a
            // one-off event.
            if case .object(let recurrence) = arguments["recurrence"] {
                event.recurrenceRules = [try self.makeRecurrenceRule(from: recurrence)]
            } else if arguments["clearRecurrence"]?.boolValue == true
                || arguments["recurrence"]?.isNull == true
            {
                event.recurrenceRules = nil
            }

            let span = EKSpan(arguments["span"]?.stringValue ?? "thisEvent")
            try self.eventStore.save(event, span: span, commit: true)

            return try self.encode(event)
        }

        Tool(
            name: "events_delete",
            description:
                "Delete a calendar event. Locate it by \"identifier\" (from events_fetch, recommended) or by \"title\". For a repeating event, pass \"occurrenceStart\" to pick an occurrence and \"span\" to choose whether to remove just that one or it and all later ones.",
            inputSchema: .object(
                properties: [
                    "identifier": .string(
                        description:
                            "Stable identifier of the event to delete (from events_fetch). Preferred over title."
                    ),
                    "title": .string(
                        description: "Exact title of the event to delete (if identifier omitted)"
                    ),
                    "occurrenceStart": .string(
                        description:
                            "Start date/time of the specific occurrence to delete. Every occurrence of a repeating event shares one identifier, so this is how you single one out.",
                        format: .dateTime
                    ),
                    "searchStart": .string(
                        description:
                            "Start of the window searched when locating by title (defaults to now).",
                        format: .dateTime
                    ),
                    "searchEnd": .string(
                        description:
                            "End of the window searched when locating by title (defaults to one year after searchStart).",
                        format: .dateTime
                    ),
                    "searchCalendar": .string(
                        description: "Restrict a title match to this calendar"
                    ),
                    "span": .string(
                        description:
                            "For a repeating event, whether to delete only the located occurrence or it and all later ones. Ignored for one-off events.",
                        default: .string("thisEvent"),
                        enum: [.string("thisEvent"), .string("futureEvents")]
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Delete Event",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.activate()

            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
                log.error("Calendar access not authorized")
                throw NSError(
                    domain: "CalendarError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Calendar access not authorized"]
                )
            }

            let event = try self.locateEvent(from: arguments)
            let span = EKSpan(arguments["span"]?.stringValue ?? "thisEvent")

            // Capture details before removal
            let deletedIdentifier = event.eventIdentifier ?? ""
            let deletedTitle = event.title ?? ""
            let calendarTitle = event.calendar?.title ?? ""
            let deletedStart = ISO8601DateFormatter().string(from: event.startDate)
            let wasRecurring = event.hasRecurrenceRules

            try self.eventStore.remove(event, span: span, commit: true)

            log.notice(
                "Deleted event \(deletedTitle, privacy: .public) with span \(span.stringValue, privacy: .public)"
            )

            return Value.object([
                "deleted": .bool(true),
                "identifier": .string(deletedIdentifier),
                "title": .string(deletedTitle),
                "calendar": .string(calendarTitle),
                "start": .string(deletedStart),
                "wasRecurring": .bool(wasRecurring),
                "span": .string(span.stringValue),
            ])
        }
    }
}
