import Foundation

/// Small, shared date-formatting helpers so copy stays consistent and human.
public enum DateFormatting {
    private static let medium: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f
    }()

    /// "Aug 15" style short day.
    public static func day(_ date: Date) -> String {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("MMMd")
        return f.string(from: date)
    }

    /// "Aug 15 – Aug 18, 2026" style range (collapses shared year/month sensibly
    /// via the OS interval formatter).
    public static func range(_ start: Date, _ end: Date) -> String {
        let f = DateIntervalFormatter()
        f.dateStyle = .medium; f.timeStyle = .none
        return f.string(from: start, to: end)
    }

    /// Absolute date for "available until" messaging, e.g. "August 18, 2026".
    public static func longDate(_ date: Date) -> String {
        let f = DateFormatter(); f.dateStyle = .long; f.timeStyle = .none
        return f.string(from: date)
    }
}
