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

/// The user's own face profile — a single reference embedding created once from
/// a selfie. Kept separate from `User` because it is sensitive and versioned
/// (re-taking a selfie bumps `version`, invalidating cached matches later).
public struct FaceProfile: Equatable, Codable, Sendable {
    public let userId: String
    public var embedding: FaceEmbedding
    public var version: Int
    public var updatedAt: Date

    public init(userId: String, embedding: FaceEmbedding, version: Int = 1, updatedAt: Date) {
        self.userId = userId
        self.embedding = embedding
        self.version = version
        self.updatedAt = updatedAt
    }
}
