import Foundation

/// A config provider backed by an in-memory value. Used in tests, SwiftUI
/// previews, and as the pre-Firebase bootstrap value. Thread-safe.
public final class StaticConfigProvider: ConfigProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var values: RemoteConfigValues

    public init(_ values: RemoteConfigValues = .default) {
        self.values = values
    }

    public var current: RemoteConfigValues {
        lock.lock(); defer { lock.unlock() }
        return values
    }

    public func set(_ values: RemoteConfigValues) {
        lock.lock(); self.values = values; lock.unlock()
    }

    public func refresh() async { /* static — nothing to fetch */ }
}

/// In-memory `ScanStateStore` for tests and previews.
public final class InMemoryScanStateStore: ScanStateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: ScanState] = [:]

    public init() {}

    public func load(eventId: String) -> ScanState {
        lock.lock(); defer { lock.unlock() }
        return storage[eventId] ?? ScanState(eventId: eventId)
    }

    public func save(_ state: ScanState) {
        lock.lock(); storage[state.eventId] = state; lock.unlock()
    }
}

/// Production `ScanStateStore` persisted in `UserDefaults` as JSON. Small,
/// device-local, survives launches. (Migrates to a file/DB if state grows.)
public final class UserDefaultsScanStateStore: ScanStateStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let prefix = "snaploop.scanstate."

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load(eventId: String) -> ScanState {
        guard let data = defaults.data(forKey: key(eventId)),
              let state = try? JSONDecoder().decode(ScanState.self, from: data)
        else { return ScanState(eventId: eventId) }
        return state
    }

    public func save(_ state: ScanState) {
        guard let data = try? JSONEncoder().encode(state) else {
            Log.scanner.error("Failed to encode scan state for event \(state.eventId, privacy: .public)")
            return
        }
        defaults.set(data, forKey: key(state.eventId))
    }

    private func key(_ eventId: String) -> String { prefix + eventId }
}
