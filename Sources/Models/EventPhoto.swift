import Foundation

public enum MediaType: String, Codable, Sendable {
    case photo
    case video
}

/// The stored, shareable record for a matched photo — the Firestore
/// `events/{eventId}/photos/{photoId}` document. Only thumbnails + metadata live
/// here; the original stays on the source device until a transfer is requested.
///
/// `sourceAssetReference` (the source device's local asset id) is present in the
/// document but **stripped before fan-out to other clients** (see security
/// rules) — only the owner and the server use it to fulfill a download.
public struct EventPhoto: Identifiable, Equatable, Codable, Sendable {
    public let id: String              // deterministic: "\(eventId):\(sourceAssetReference)"
    public let eventId: String
    public let sourceUserId: String
    public let capturedAt: Date
    public var thumbnailPath: String?
    public var previewPath: String?
    public let width: Int
    public let height: Int
    public let mediaType: MediaType
    public var matchedUserIds: [String]
    public let createdAt: Date
    public let sourceAssetReference: String   // never exposed to other clients

    public init(
        eventId: String,
        sourceUserId: String,
        capturedAt: Date,
        thumbnailPath: String? = nil,
        previewPath: String? = nil,
        width: Int,
        height: Int,
        mediaType: MediaType,
        matchedUserIds: [String],
        createdAt: Date,
        sourceAssetReference: String
    ) {
        self.id = "\(eventId):\(sourceAssetReference)"
        self.eventId = eventId
        self.sourceUserId = sourceUserId
        self.capturedAt = capturedAt
        self.thumbnailPath = thumbnailPath
        self.previewPath = previewPath
        self.width = width
        self.height = height
        self.mediaType = mediaType
        self.matchedUserIds = matchedUserIds
        self.createdAt = createdAt
        self.sourceAssetReference = sourceAssetReference
    }

    /// The client-safe projection — what other members are allowed to read.
    /// Drops `sourceAssetReference` so no one can address another device's
    /// library.
    public func redactedForClients() -> EventPhoto {
        EventPhoto(
            eventId: eventId, sourceUserId: sourceUserId, capturedAt: capturedAt,
            thumbnailPath: thumbnailPath, previewPath: previewPath,
            width: width, height: height, mediaType: mediaType,
            matchedUserIds: matchedUserIds, createdAt: createdAt,
            sourceAssetReference: "")   // redacted
    }
}
