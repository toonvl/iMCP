import EventKit

extension EKEventAvailability {
    init(_ string: String) {
        switch string.lowercased() {
        case "busy": self = .busy
        case "free": self = .free
        case "tentative": self = .tentative
        case "unavailable": self = .unavailable
        default: self = .busy
        }
    }

    static var allCases: [EKEventAvailability] {
        return [.busy, .free, .tentative, .unavailable]
    }

    var stringValue: String {
        switch self {
        case .busy: return "busy"
        case .free: return "free"
        case .tentative: return "tentative"
        case .unavailable: return "unavailable"
        default: return "unknown"
        }
    }
}

extension EKEventStatus {
    init(_ string: String) {
        switch string.lowercased() {
        case "none": self = .none
        case "tentative": self = .tentative
        case "confirmed": self = .confirmed
        case "canceled": self = .canceled
        default: self = .none
        }
    }
}

extension EKEvent {
    /// Whether the current user organizes/owns this event, as opposed to having
    /// been invited to it by someone else.
    ///
    /// An event with no organizer (e.g. a plain event you created, a birthday, or
    /// a subscribed holiday) is treated as your own. An event that has an organizer
    /// is yours only if that organizer is the current user; otherwise it was created
    /// by someone else and shared/invited to you (e.g. a colleague's leave).
    var isOrganizedByCurrentUser: Bool {
        guard let organizer = organizer else { return true }
        return organizer.isCurrentUser
    }

    /// Display name of the organizer, if the event was organized by someone else.
    /// Returns `nil` for events you own or when no organizer information is available.
    var organizerDisplayName: String? {
        guard let organizer = organizer, !organizer.isCurrentUser else { return nil }
        return organizer.name
            ?? organizer.url.absoluteString.replacingOccurrences(
                of: "mailto:",
                with: ""
            )
    }
}

extension EKRecurrenceFrequency {
    init(_ string: String) {
        switch string.lowercased() {
        case "daily": self = .daily
        case "weekly": self = .weekly
        case "monthly": self = .monthly
        case "yearly": self = .yearly
        default: self = .daily
        }
    }

    /// Strict counterpart to `init(_:)`, which falls back to `.daily` for an
    /// unrecognized string. Returns `nil` instead, so a caller can report a bad
    /// frequency rather than silently creating a daily series.
    init?(validating string: String) {
        switch string.lowercased() {
        case "daily": self = .daily
        case "weekly": self = .weekly
        case "monthly": self = .monthly
        case "yearly": self = .yearly
        default: return nil
        }
    }

    static var allCases: [EKRecurrenceFrequency] {
        return [.daily, .weekly, .monthly, .yearly]
    }

    var stringValue: String {
        switch self {
        case .daily: return "daily"
        case .weekly: return "weekly"
        case .monthly: return "monthly"
        case .yearly: return "yearly"
        @unknown default: return "unknown"
        }
    }
}

extension EKWeekday {
    init?(validating string: String) {
        switch string.lowercased() {
        case "sunday", "sun": self = .sunday
        case "monday", "mon": self = .monday
        case "tuesday", "tue": self = .tuesday
        case "wednesday", "wed": self = .wednesday
        case "thursday", "thu": self = .thursday
        case "friday", "fri": self = .friday
        case "saturday", "sat": self = .saturday
        default: return nil
        }
    }

    static var allCases: [EKWeekday] {
        return [.sunday, .monday, .tuesday, .wednesday, .thursday, .friday, .saturday]
    }

    var stringValue: String {
        switch self {
        case .sunday: return "sunday"
        case .monday: return "monday"
        case .tuesday: return "tuesday"
        case .wednesday: return "wednesday"
        case .thursday: return "thursday"
        case .friday: return "friday"
        case .saturday: return "saturday"
        @unknown default: return "unknown"
        }
    }
}

extension EKSpan {
    /// Whether an edit applies to a single occurrence or to that occurrence and
    /// every later one. Non-recurring events are unaffected by the distinction.
    init(_ string: String) {
        switch string.lowercased() {
        case "futureevents", "future", "futureoccurrences": self = .futureEvents
        default: self = .thisEvent
        }
    }

    var stringValue: String {
        switch self {
        case .thisEvent: return "thisEvent"
        case .futureEvents: return "futureEvents"
        @unknown default: return "unknown"
        }
    }
}

extension EKReminderPriority {
    static func from(string: String) -> EKReminderPriority {
        switch string.lowercased() {
        case "high": return .high
        case "medium": return .medium
        case "low": return .low
        default: return .none
        }
    }

    static var allCases: [EKReminderPriority] {
        return [.none, .low, .medium, .high]
    }

    var stringValue: String {
        switch self {
        case .high: return "high"
        case .medium: return "medium"
        case .low: return "low"
        case .none: return "none"
        @unknown default: return "unknown"
        }
    }
}
