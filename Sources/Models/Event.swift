import Foundation

/// An event — the container that scopes photo collection to a time window and a
/// set of participants. The `id` and `joinCode` are **stable for the life of
/// the event** and never change when name/dates/cover are edited (treat it like
/// a Google Doc: stable ID, stable URL).
public struct Event: Identifiable, Equatable, Codable, Sendable {
    public let id: String                 // stable, server-assigned, never reused
    public let joinCode: String           // stable short code (also encoded in the QR)
    public let creatorUserId: String

    // Mutable presentation details — editing these must NOT touch id/joinCode.
    public var name: String
    public var coverImagePath: String?    // Storage path, optional
    public var locationName: String?

    // Time window. `endsAt` is inclusive of the whole day it falls on at the
    // scanning layer; lifecycle math treats these as precise instants.
    public var startsAt: Date
    public var endsAt: Date

    public let createdAt: Date

    public init(
        id: String,
        joinCode: String,
        creatorUserId: String,
        name: String,
        coverImagePath: String? = nil,
        locationName: String? = nil,
        startsAt: Date,
        endsAt: Date,
        createdAt: Date
    ) {
        self.id = id
        self.joinCode = joinCode
        self.creatorUserId = creatorUserId
        self.name = name
        self.coverImagePath = coverImagePath
        self.locationName = locationName
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.createdAt = createdAt
    }

    /// The half-open date interval `[startsAt, endsAt]` used to filter the photo
    /// library. Callers scan only assets created inside this range.
    public var dateRange: ClosedRange<Date> { startsAt...endsAt }
}

/// A participant's membership in an event, plus the reference embedding used to
/// match *this participant* across everyone's photos. Embeddings are copied
/// into the event roster (with the profile version they came from) so the event
/// is self-contained and a later profile change can be detected.
public struct EventParticipant: Identifiable, Equatable, Codable, Sendable {
    public var id: String { userId }
    public let userId: String
    public var displayName: String?
    public var faceEmbedding: FaceEmbedding
    public var faceProfileVersion: Int
    public let joinedAt: Date

    public init(
        userId: String,
        displayName: String?,
        faceEmbedding: FaceEmbedding,
        faceProfileVersion: Int,
        joinedAt: Date
    ) {
        self.userId = userId
        self.displayName = displayName
        self.faceEmbedding = faceEmbedding
        self.faceProfileVersion = faceProfileVersion
        self.joinedAt = joinedAt
    }
}
