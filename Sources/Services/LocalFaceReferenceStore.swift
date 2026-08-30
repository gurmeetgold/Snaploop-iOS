import CryptoKit
import Foundation
import Security
import UIKit

/// Stores face-reference previews locally on this device.
///
/// Raw face-reference images are never uploaded to Firestore. The matching
/// profile stored remotely contains mathematical descriptors only. We keep the
/// guided selfie and optional gallery reference separately so every UI surface
/// can consistently prefer the guided reference, then fall back to the gallery
/// reference, without ever using arbitrary matched photos.
///
/// To avoid an empty avatar after reinstall on the same iPhone, a small
/// display-only thumbnail of the guided selfie is also mirrored into the
/// app's device-only Keychain. It is not synchronized through iCloud, is not
/// backed up, is never sent to Firebase, and is deleted with Face Setup.
///
/// Privacy hardening:
/// - full local files use complete iOS data protection;
/// - the FaceReferences folder/files are excluded from device backups;
/// - the small fallback thumbnail uses WhenUnlockedThisDeviceOnly Keychain
///   protection and never leaves this device;
/// - filenames/accounts use a one-way SHA-256 account key rather than exposing
///   a Firebase UID;
/// - older filename formats are migrated locally on first read.
public enum LocalFaceReferenceStore {
    public enum Kind: String, Sendable {
        case guided
        case gallery
    }

    private static let protectedWriteOptions: Data.WritingOptions = [.atomic, .completeFileProtection]
    private static let keychainService = "com.gurmeetchhiber.snaploop.app.face-display-thumbnail"
    private static let displayThumbnailMaxSide: CGFloat = 192

    /// Compatibility entry point retained for older callers. New code should
    /// specify a reference kind explicitly.
    public static func save(_ jpegData: Data, userId: String) throws {
        try saveProtected(jpegData, to: fileURL(userId: userId, suffix: "legacy"))
        try? savePersistentDisplayThumbnail(from: jpegData, userId: userId)
    }

    public static func save(_ jpegData: Data, userId: String, kind: Kind) throws {
        try saveProtected(jpegData, to: fileURL(userId: userId, suffix: kind.rawValue))
        if kind == .guided {
            try? savePersistentDisplayThumbnail(from: jpegData, userId: userId)
        }
    }

    public static func load(userId: String) -> Data? {
        load(userId: userId, kind: .guided)
            ?? load(userId: userId, kind: .gallery)
            ?? loadLegacy(userId: userId)
            ?? loadPersistentDisplayThumbnail(userId: userId)
    }

    public static func load(userId: String, kind: Kind) -> Data? {
        if let url = try? fileURL(userId: userId, suffix: kind.rawValue),
           let data = try? Data(contentsOf: url) {
            if kind == .guided {
                // Seed the reinstall-safe display thumbnail for existing users
                // the first time this newer build reads their local selfie.
                try? savePersistentDisplayThumbnail(from: data, userId: userId)
            }
            return data
        }

        // Migrate the pre-hardening Base64-UID filename if it exists. The
        // migration never leaves the image in two filesystem locations after a
        // successful protected write.
        if let oldURL = try? legacyEncodedFileURL(userId: userId, suffix: kind.rawValue),
           let data = try? Data(contentsOf: oldURL) {
            if (try? save(data, userId: userId, kind: kind)) != nil {
                try? FileManager.default.removeItem(at: oldURL)
            }
            return data
        }

        // Older Face Setup builds could leave the display reference under the
        // gallery/legacy slot while the cloud numerical profile remained active.
        // When a guided preview is requested, recover those device-local images
        // before falling back to the Keychain thumbnail. Nothing is uploaded.
        if kind == .guided {
            if let gallery = load(userId: userId, kind: .gallery) {
                try? savePersistentDisplayThumbnail(from: gallery, userId: userId)
                return gallery
            }
            if let legacy = loadLegacy(userId: userId) {
                return legacy
            }
            return loadPersistentDisplayThumbnail(userId: userId)
        }

        return nil
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
        deletePersistentDisplayThumbnail(userId: userId)
    }

    private static func loadLegacy(userId: String) -> Data? {
        if let url = try? fileURL(userId: userId, suffix: "legacy"),
           let data = try? Data(contentsOf: url) {
            try? savePersistentDisplayThumbnail(from: data, userId: userId)
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

    private static func savePersistentDisplayThumbnail(from jpegData: Data, userId: String) throws {
        guard let thumbnail = makeDisplayThumbnail(from: jpegData), !thumbnail.isEmpty else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: accountKey(userId),
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: thumbnail,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(updateStatus))
        }

        var addQuery = query
        attributes.forEach { addQuery[$0.key] = $0.value }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus))
        }
    }

    private static func loadPersistentDisplayThumbnail(userId: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: accountKey(userId),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func deletePersistentDisplayThumbnail(userId: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: accountKey(userId),
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func makeDisplayThumbnail(from jpegData: Data) -> Data? {
        guard let image = UIImage(data: jpegData), image.size.width > 0, image.size.height > 0 else { return nil }
        let longestSide = max(image.size.width, image.size.height)
        let scale = min(1, displayThumbnailMaxSide / longestSide)
        let target = CGSize(
            width: max(1, floor(image.size.width * scale)),
            height: max(1, floor(image.size.height * scale))
        )
        let renderer = UIGraphicsImageRenderer(size: target)
        return renderer.jpegData(withCompressionQuality: 0.72) { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    /// One-way account key used only for local filename/Keychain isolation. It
    /// avoids exposing the Firebase UID in directory listings or diagnostics.
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
