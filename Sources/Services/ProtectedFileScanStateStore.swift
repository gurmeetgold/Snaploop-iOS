import CryptoKit
import Foundation

/// Production persistence for the Change-4 local photo corpus and recipient
/// cursors. Candidate photo-face embeddings are biometric-derived data, so they
/// do not belong in UserDefaults. Files live only in Application Support, are
/// excluded from backup and use iOS Data Protection after the first device
/// unlock so background Event sync can still resume safely.
public final class ProtectedFileScanStateStore: ScanStateStore, @unchecked Sendable {
    private let lock = NSLock()
    private let fileManager: FileManager
    private let directory: URL
    private let isReady: Bool

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        directory = base
            .appendingPathComponent("SnapLoop", isDirectory: true)
            .appendingPathComponent("PhotoCorpus-v1", isDirectory: true)

        var ready = false
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var mutableDirectory = directory
            try mutableDirectory.setResourceValues(resourceValues)
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: directory.path
            )
            ready = true
        } catch {
            Log.scanner.error("Could not prepare protected local photo-corpus storage")
        }
        isReady = ready
    }

    public func load(eventId: String) -> ScanState {
        lock.lock()
        defer { lock.unlock() }

        guard isReady,
              let data = try? Data(contentsOf: fileURL(for: eventId)),
              let state = try? PropertyListDecoder().decode(ScanState.self, from: data),
              state.eventId == eventId else {
            return ScanState(eventId: eventId)
        }
        return state
    }

    public func save(_ state: ScanState) {
        lock.lock()
        defer { lock.unlock() }

        guard isReady else { return }
        do {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let data = try encoder.encode(state)
            let url = fileURL(for: state.eventId)
            try data.write(to: url, options: .atomic)
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var mutableURL = url
            try mutableURL.setResourceValues(resourceValues)
        } catch {
            // Do not include the state namespace in logs: it contains a
            // pseudonymous source-installation identifier.
            Log.scanner.error("Could not persist protected local photo-corpus state")
        }
    }

    private func fileURL(for stateKey: String) -> URL {
        let digest = SHA256.hash(data: Data(stateKey.utf8))
        let filename = digest.map { String(format: "%02x", $0) }.joined() + ".plist"
        return directory.appendingPathComponent(filename, isDirectory: false)
    }
}
