import Foundation

/// Stores face-reference previews locally on this device.
///
/// Raw face-reference images are never uploaded to Firestore. The matching
/// profile stored remotely contains mathematical descriptors only. We keep the
/// guided selfie and optional gallery reference separately so every UI surface
/// can consistently prefer the guided reference, then fall back to the gallery
/// reference, without ever using arbitrary matched photos.
public enum LocalFaceReferenceStore {
    public enum Kind: String, Sendable {
        case guided
        case gallery
    }

    private static let protectedWriteOptions: Data.WritingOptions = [.atomic, .completeFileProtection]

    public static func save(_ jpegData: Data, userId: String) throws {
        try jpegData.write(
            to: try fileURL(userId: userId, suffix: "legacy"),
            options: protectedWriteOptions
        )
    }

    public static func save(_ jpegData: Data, userId: String, kind: Kind) throws {
        try jpegData.write(
            to: try fileURL(userId: userId, suffix: kind.rawValue),
            options: protectedWriteOptions
        )
    }

    public static func load(userId: String) -> Data? {
        load(userId: userId, kind: .guided)
            ?? load(userId: userId, kind: .gallery)
            ?? loadLegacy(userId: userId)
    }

    public static func load(userId: String, kind: Kind) -> Data? {
        guard let url = try? fileURL(userId: userId, suffix: kind.rawValue) else { return nil }
        return try? Data(contentsOf: url)
    }

    public static func delete(userId: String) {
        for suffix in [Kind.guided.rawValue, Kind.gallery.rawValue, "legacy"] {
            guard let url = try? fileURL(userId: userId, suffix: suffix) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
        if let legacy = try? legacyFileURL(userId: userId) {
            try? FileManager.default.removeItem(at: legacy)
        }
    }

    private static func loadLegacy(userId: String) -> Data? {
        guard let url = try? legacyFileURL(userId: userId) else { return nil }
        return try? Data(contentsOf: url)
            ?? (try? Data(contentsOf: fileURL(userId: userId, suffix: "legacy")))
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
        return folder
    }

    private static func safeUserId(_ userId: String) -> String {
        Data(userId.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
    }

    private static func fileURL(userId: String, suffix: String) throws -> URL {
        try folderURL().appendingPathComponent("\(safeUserId(userId)).\(suffix).jpg")
    }

    private static func legacyFileURL(userId: String) throws -> URL {
        try folderURL().appendingPathComponent("\(safeUserId(userId)).jpg")
    }
}
