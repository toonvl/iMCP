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
        return organizer.name ?? organizer.url.absoluteString.replacingOccurrences(
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
