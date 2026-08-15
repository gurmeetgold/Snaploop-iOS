import Foundation
import os

/// Thin wrapper over `os.Logger` with app-wide subsystem and named categories.
/// Keeps logging consistent and greppable, and gives us one place to route to
/// Crashlytics later without touching call sites.
public enum Log {
    private static let subsystem = "com.snaploop.app"

    public static let auth      = Logger(subsystem: subsystem, category: "auth")
    public static let scanner   = Logger(subsystem: subsystem, category: "scanner")
    public static let matching  = Logger(subsystem: subsystem, category: "matching")
    public static let events    = Logger(subsystem: subsystem, category: "events")
    public static let transfers = Logger(subsystem: subsystem, category: "transfers")
    public static let config    = Logger(subsystem: subsystem, category: "config")
    public static let app       = Logger(subsystem: subsystem, category: "app")
}
