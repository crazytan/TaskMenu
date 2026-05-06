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

    private static let dateOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'00:00:00.000'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private static let displayFormatter: DateFormatter = {
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

    static func parseGoogleTaskDueDate(_ string: String, calendar: Calendar = .current) -> Date? {
        guard let date = parseRFC3339(string) else { return nil }

        let components = googleTaskDueDateComponents(from: date)
        guard
            let year = components.year,
            let month = components.month,
            let day = components.day,
            let localDate = calendar.date(from: DateComponents(year: year, month: month, day: day))
        else {
            return nil
        }

        return calendar.startOfDay(for: localDate)
    }

    static func formatGoogleTaskDueDate(_ date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard
            let year = components.year,
            let month = components.month,
            let day = components.day
        else {
            return formatRFC3339(date)
        }

        return String(format: "%04d-%02d-%02dT00:00:00.000Z", year, month, day)
    }

    static func displayString(_ date: Date) -> String {
        displayFormatter.string(from: date)
    }

    static func relativeString(from date: Date, relativeTo now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return "Today"
        } else if isDate(date, offsetBy: 1, from: now, calendar: calendar) {
            return "Tomorrow"
        } else if isDate(date, offsetBy: -1, from: now, calendar: calendar) {
            return "Yesterday"
        } else {
            return displayString(date)
        }
    }

    private static func googleTaskDueDateComponents(from date: Date) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.dateComponents([.year, .month, .day], from: date)
    }

    private static func isDate(_ date: Date, offsetBy dayOffset: Int, from now: Date, calendar: Calendar) -> Bool {
        guard let comparisonDate = calendar.date(
            byAdding: .day,
            value: dayOffset,
            to: calendar.startOfDay(for: now)
        ) else {
            return false
        }

        return calendar.isDate(date, inSameDayAs: comparisonDate)
    }
}
