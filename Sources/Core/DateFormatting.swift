import Foundation

/// Small, shared date-formatting helpers so copy stays consistent and human.
public enum DateFormatting {
    private static let medium: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f
    }()

    /// "Aug 15" style short day.
    public static func day(_ date: Date, timeZone: TimeZone? = nil) -> String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        if let timeZone { f.timeZone = timeZone }
        return f.string(from: date)
    }

    /// "Aug 15 – Aug 18, 2026" style range (collapses shared year/month sensibly
    /// via the OS interval formatter). Canonical Events pass their persisted
    /// Event timezone so every participant sees the organizer-selected civil
    /// dates even after travelling to another timezone.
    public static func range(_ start: Date, _ end: Date, timeZone: TimeZone? = nil) -> String {
        let f = DateIntervalFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        if let timeZone { f.timeZone = timeZone }
        return f.string(from: start, to: end)
            .replacingOccurrences(of: " ", with: "\u{00A0}")
    }

    /// Absolute date for "available until" messaging, e.g. "August 18, 2026".
    public static func longDate(_ date: Date, timeZone: TimeZone? = nil) -> String {
        let f = DateFormatter(); f.dateStyle = .long; f.timeStyle = .none
        if let timeZone { f.timeZone = timeZone }
        return f.string(from: date)
    }

    /// Fixed compact photo date, e.g. "29/08/26".
    public static func compactNumeric(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "dd/MM/yy"
        return f.string(from: date)
    }
}
