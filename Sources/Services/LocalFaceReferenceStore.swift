import Foundation

/// Stores the user's chosen face-reference crop locally on this device.
///
/// The reference image itself is not uploaded to Firestore. Firebase stores only
/// the descriptor. Keeping the preview local lets the You tab show which photo
/// was used without increasing biometric/photo exposure in the cloud.
public enum LocalFaceReferenceStore {

    public static func save(
        _ jpegData: Data,
        userId: String
    ) throws {
        let url = try fileURL(userId: userId)
        try jpegData.write(
            to: url,
            options: [.atomic]
        )
    }

    public static func load(
        userId: String
    ) -> Data? {
        guard let url = try? fileURL(userId: userId) else {
            return nil
        }
        return try? Data(contentsOf: url)
    }

    public static func delete(
        userId: String
    ) {
        guard let url = try? fileURL(userId: userId) else {
            return
        }
        try? FileManager.default.removeItem(at: url)
    }

    private static func fileURL(
        userId: String
    ) throws -> URL {
        let manager = FileManager.default

        let base = try manager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        let folder = base
            .appendingPathComponent(
                "SnapLoop",
                isDirectory: true
            )
            .appendingPathComponent(
                "FaceReferences",
                isDirectory: true
            )

        try manager.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )

        let safeId = Data(userId.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")

        return folder.appendingPathComponent(
            "\(safeId).jpg"
        )
    }
}
