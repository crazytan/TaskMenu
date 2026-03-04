import Foundation

enum DateFormatting: Sendable {
    nonisolated(unsafe) private static let rfc3339Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let rfc3339FallbackFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    nonisolated(unsafe) private static let dateOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'00:00:00.000'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    nonisolated(unsafe) private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    static func parseRFC3339(_ string: String) -> Date? {
        rfc3339Formatter.date(from: string)
            ?? rfc3339FallbackFormatter.date(from: string)
    }

    static func formatRFC3339(_ date: Date) -> String {
        dateOnlyFormatter.string(from: date)
    }

    static func displayString(_ date: Date) -> String {
        displayFormatter.string(from: date)
    }

    static func relativeString(from date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInTomorrow(date) {
            return "Tomorrow"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            return displayString(date)
        }
    }
}
