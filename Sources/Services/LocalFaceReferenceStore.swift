import CryptoKit
import Foundation

/// Stores face-reference previews locally on this device.
///
/// Raw face-reference images are never uploaded to Firestore. The matching
/// profile stored remotely contains mathematical descriptors only. We keep the
/// guided selfie and optional gallery reference separately so every UI surface
/// can consistently prefer the guided reference, then fall back to the gallery
/// reference, without ever using arbitrary matched photos.
///
/// Privacy hardening:
/// - files use complete iOS data protection;
/// - the FaceReferences folder/files are excluded from device backups;
/// - filenames use a one-way SHA-256 account key rather than exposing a
///   Firebase UID in the filesystem;
/// - older filename formats are migrated locally on first read.
public enum LocalFaceReferenceStore {
    public enum Kind: String, Sendable {
        case guided
        case gallery
    }

    private static let protectedWriteOptions: Data.WritingOptions = [.atomic, .completeFileProtection]

    /// Compatibility entry point retained for older callers. New code should
    /// specify a reference kind explicitly.
    public static func save(_ jpegData: Data, userId: String) throws {
        try saveProtected(jpegData, to: fileURL(userId: userId, suffix: "legacy"))
    }

    public static func save(_ jpegData: Data, userId: String, kind: Kind) throws {
        try saveProtected(jpegData, to: fileURL(userId: userId, suffix: kind.rawValue))
    }

    public static func load(userId: String) -> Data? {
        load(userId: userId, kind: .guided)
            ?? load(userId: userId, kind: .gallery)
            ?? loadLegacy(userId: userId)
    }

    public static func load(userId: String, kind: Kind) -> Data? {
        if let url = try? fileURL(userId: userId, suffix: kind.rawValue),
           let data = try? Data(contentsOf: url) {
            return data
        }

        // Migrate the pre-hardening Base64-UID filename if it exists. The
        // migration never leaves the image in two locations after a successful
        // protected write.
        guard let oldURL = try? legacyEncodedFileURL(userId: userId, suffix: kind.rawValue),
              let data = try? Data(contentsOf: oldURL) else { return nil }
        if (try? save(data, userId: userId, kind: kind)) != nil {
            try? FileManager.default.removeItem(at: oldURL)
        }
        return data
    }

    public static func delete(userId: String) {
        let suffixes = [Kind.guided.rawValue, Kind.gallery.rawValue, "legacy"]
        for suffix in suffixes {
            if let url = try? fileURL(userId: userId, suffix: suffix) {
                try? FileManager.default.removeItem(at: url)
            }
            if let oldURL = try? legacyEncodedFileURL(userId: userId, suffix: suffix) {
                try? FileManager.default.removeItem(at: oldURL)
            }
        }
        if let oldUnsuffixed = try? legacyUnsuffixedFileURL(userId: userId) {
            try? FileManager.default.removeItem(at: oldUnsuffixed)
        }
    }

    private static func loadLegacy(userId: String) -> Data? {
        if let url = try? fileURL(userId: userId, suffix: "legacy"),
           let data = try? Data(contentsOf: url) {
            return data
        }

        for oldURL in [
            try? legacyEncodedFileURL(userId: userId, suffix: "legacy"),
            try? legacyUnsuffixedFileURL(userId: userId),
        ].compactMap({ $0 }) {
            guard let data = try? Data(contentsOf: oldURL) else { continue }
            if (try? save(data, userId: userId)) != nil {
                try? FileManager.default.removeItem(at: oldURL)
            }
            return data
        }
        return nil
    }

    private static func saveProtected(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: protectedWriteOptions)
        try excludeFromBackup(url)
    }

    private static func folderURL() throws -> URL {
        let manager = FileManager.default
        let base = try manager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let folder = base
            .appendingPathComponent("SnapLoop", isDirectory: true)
            .appendingPathComponent("FaceReferences", isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        try manager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: folder.path
        )
        try excludeFromBackup(folder)
        return folder
    }

    private static func excludeFromBackup(_ url: URL) throws {
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableURL.setResourceValues(values)
    }

    /// One-way account key used only for local filename isolation. It avoids
    /// exposing the Firebase UID in directory listings or diagnostic bundles.
    private static func accountKey(_ userId: String) -> String {
        SHA256.hash(data: Data(userId.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Previous versions used reversible Base64-encoded UIDs. Kept only so an
    /// existing on-device preview can be migrated without asking for a rescan.
    private static func legacyEncodedUserId(_ userId: String) -> String {
        Data(userId.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
    }

    private static func fileURL(userId: String, suffix: String) throws -> URL {
        try folderURL().appendingPathComponent("\(accountKey(userId)).\(suffix).jpg")
    }

    private static func legacyEncodedFileURL(userId: String, suffix: String) throws -> URL {
        try folderURL().appendingPathComponent("\(legacyEncodedUserId(userId)).\(suffix).jpg")
    }

    private static func legacyUnsuffixedFileURL(userId: String) throws -> URL {
        try folderURL().appendingPathComponent("\(legacyEncodedUserId(userId)).jpg")
    }
}
