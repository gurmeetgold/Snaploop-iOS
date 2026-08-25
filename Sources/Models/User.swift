import Foundation

/// A registered SnapLoop user. Identity is a phone number (verified via OTP);
/// there is no username, profile, or social graph — this is not a social app.
public struct User: Identifiable, Equatable, Codable, Sendable {
    public let id: String                 // Firebase Auth UID
    public var phoneNumber: String        // E.164
    public var displayName: String?       // optional, user-set, for event rosters only
    public var hasFaceProfile: Bool       // whether a face profile has been set up
    public let createdAt: Date

    public init(
        id: String,
        phoneNumber: String,
        displayName: String? = nil,
        hasFaceProfile: Bool = false,
        createdAt: Date
    ) {
        self.id = id
        self.phoneNumber = phoneNumber
        self.displayName = displayName
        self.hasFaceProfile = hasFaceProfile
        self.createdAt = createdAt
    }
}

/// One enrollment template for a specific appearance/pose.
///
/// The raw image is never part of this model. Only the normalized descriptor
/// plus minimal quality/pose metadata is persisted.
public struct FaceTemplate: Identifiable, Equatable, Codable, Sendable {
    public enum Pose: String, Codable, Sendable, CaseIterable {
        case center
        case sideA
        case sideB
        case tilted
        case alternate
        case imported
    }

    public let id: String
    public var embedding: FaceEmbedding
    public var pose: Pose
    public var quality: Double
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        embedding: FaceEmbedding,
        pose: Pose,
        quality: Double = 1.0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.embedding = embedding
        self.pose = pose
        self.quality = quality
        self.createdAt = createdAt
    }

    /// Returns at most one descriptor per enrollment pose. This prevents a
    /// duplicated/corrupted template from counting twice as independent
    /// corroboration near the match threshold. When duplicates exist for one
    /// pose, keep the highest-quality capture (newest wins exact quality ties).
    public static func distinctPoseEmbeddings(from templates: [FaceTemplate]) -> [FaceEmbedding] {
        Pose.allCases.compactMap { pose in
            templates
                .filter { $0.pose == pose && $0.quality.isFinite }
                .max { lhs, rhs in
                    if lhs.quality != rhs.quality { return lhs.quality < rhs.quality }
                    return lhs.createdAt < rhs.createdAt
                }?
                .embedding
        }
    }
}

/// The user's own face profile.
///
/// `embedding` remains as a compatibility/centroid descriptor for older code
/// and migrations. `templates` is the authoritative multi-pose enrollment set
/// used by the matcher.
///
/// No raw enrollment frame is stored in Firestore.
public struct FaceProfile: Equatable, Codable, Sendable {
    public let userId: String
    public var embedding: FaceEmbedding
    public var templates: [FaceTemplate]
    public var version: Int
    public var updatedAt: Date

    public init(
        userId: String,
        embedding: FaceEmbedding,
        templates: [FaceTemplate] = [],
        version: Int = 1,
        updatedAt: Date
    ) {
        self.userId = userId
        self.embedding = embedding
        self.templates = templates
        self.version = version
        self.updatedAt = updatedAt
    }

    /// Opaque identity revision for this exact enrollment. Template IDs are
    /// random identifiers, not biometric vectors. A fresh guided enrollment
    /// receives new IDs, so caches and cloud matches can be invalidated without
    /// persisting or exposing any additional biometric measurement.
    public var faceProfileRevision: String {
        let templateIds = templates.map(\.id).filter { !$0.isEmpty }.sorted()
        guard !templateIds.isEmpty else { return "" }
        return "v\(version):\(templateIds.joined(separator: "|"))"
    }

    /// New code should compare against this set. Old profiles automatically
    /// degrade to their single compatibility embedding. Multi-template profiles
    /// expose one high-quality descriptor per distinct enrollment pose so two
    /// duplicate records cannot satisfy the corroboration rule by themselves.
    public var effectiveEmbeddings: [FaceEmbedding] {
        guard !templates.isEmpty else { return [embedding] }
        let distinct = FaceTemplate.distinctPoseEmbeddings(from: templates)
        return distinct.isEmpty ? [embedding] : distinct
    }
}
