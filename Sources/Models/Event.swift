import Foundation

/// Presentation-only grouping for an event. Affects copy/iconography, never
/// architecture or matching behavior.
public enum EventCategory: String, Codable, CaseIterable, Sendable {
    case trip, wedding, party, birthday, conference, family, sports, other

    public var displayName: String {
        switch self {
        case .trip: return "Trip"
        case .wedding: return "Wedding"
        case .party: return "Party"
        case .birthday: return "Birthday"
        case .conference: return "Conference"
        case .family: return "Family"
        case .sports: return "Sports"
        case .other: return "Event"
        }
    }

    public var systemImage: String {
        switch self {
        case .trip: return "airplane"
        case .wedding: return "heart.fill"
        case .party: return "party.popper.fill"
        case .birthday: return "birthday.cake.fill"
        case .conference: return "person.3.fill"
        case .family: return "house.fill"
        case .sports: return "sportscourt.fill"
        case .other: return "calendar"
        }
    }
}

/// Lifecycle state persisted on the event. Distinct from the *computed*
/// `EventLifecycle.Status` (which derives from the clock): `status` records an
/// explicit organizer action ("End Event") that can end an event early,
/// independent of its dates.
public enum EventStatus: String, Codable, Sendable {
    case active            // running normally
    case endedByOrganizer  // organizer tapped "End Event" before the date
    case expired           // past end + grace (set by a scheduled cleanup job)
}

/// An event — the container that scopes photo collection to a time window and a
/// set of participants. The `id`, `joinCode`, and `inviteToken` are **stable
/// for the life of the event** and never change when name/dates/cover are
/// edited (treat it like a Google Doc: stable ID, stable URL).
public struct Event: Identifiable, Equatable, Codable, Sendable {
    public let id: String                 // stable, server-assigned, never reused
    public let joinCode: String           // stable short code (also shown as QR)
    public let inviteToken: String        // stable opaque token used in the invite URL
    public let creatorUserId: String

    // Mutable presentation details — editing these must NOT touch the identity
    // fields above.
    public var name: String
    public var category: EventCategory
    public var coverImagePath: String?    // Storage path, optional
    public var locationName: String?

    // Time window. `startsAt` may be in the past ("Catch-up Scan"). Lifecycle
    // math treats these as precise instants; scanning treats the range inclusively.
    public var startsAt: Date
    public var endsAt: Date

    public var status: EventStatus
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        joinCode: String,
        inviteToken: String = "",
        creatorUserId: String,
        name: String,
        category: EventCategory = .other,
        coverImagePath: String? = nil,
        locationName: String? = nil,
        startsAt: Date,
        endsAt: Date,
        status: EventStatus = .active,
        createdAt: Date,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.joinCode = joinCode
        self.inviteToken = inviteToken
        self.creatorUserId = creatorUserId
        self.name = name
        self.category = category
        self.coverImagePath = coverImagePath
        self.locationName = locationName
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    /// The inclusive date interval `[startsAt, endsAt]` used to filter the photo
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
