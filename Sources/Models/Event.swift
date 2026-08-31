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

/// Persisted organizer-controlled lifecycle state. Date-based lifecycle is
/// computed separately by `EventLifecycle`.
public enum EventStatus: String, Codable, Sendable {
    case active
    case endedByOrganizer
    case deletedByOrganizer
    case expired
}

public struct Event: Identifiable, Equatable, Codable, Sendable {
    public let id: String
    public let joinCode: String
    public let inviteToken: String
    public let creatorUserId: String

    public var name: String
    public var category: EventCategory
    public var coverImagePath: String?
    public var locationName: String?

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

    /// Event dates are selected as calendar days in the UI, so scanning must
    /// include the entire first and last selected day regardless of the hidden
    /// time component retained by a date-only DatePicker.
    public var dateRange: ClosedRange<Date> {
        let calendar = Calendar.current
        let lower = calendar.startOfDay(for: startsAt)
        let endStart = calendar.startOfDay(for: endsAt)
        let upper = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: endStart)
            ?? endsAt
        return lower...max(lower, upper)
    }
}

public struct EventParticipant: Identifiable, Equatable, Codable, Sendable {
    public var id: String { userId }
    public let userId: String
    public var displayName: String?
    public var phoneNumber: String?
    public var faceIdentityId: String?
    public var faceEmbedding: FaceEmbedding
    public var faceTemplates: [FaceTemplate]
    public var faceProfileVersion: Int
    public let joinedAt: Date

    public init(
        userId: String,
        displayName: String?,
        phoneNumber: String? = nil,
        faceIdentityId: String? = nil,
        faceEmbedding: FaceEmbedding,
        faceTemplates: [FaceTemplate] = [],
        faceProfileVersion: Int,
        joinedAt: Date
    ) {
        self.userId = userId
        self.displayName = displayName
        self.phoneNumber = phoneNumber
        self.faceIdentityId = faceIdentityId
        self.faceEmbedding = faceEmbedding
        self.faceTemplates = faceTemplates
        self.faceProfileVersion = faceProfileVersion
        self.joinedAt = joinedAt
    }

    public var stableFaceIdentityId: String {
        faceIdentityId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Audit revision for the exact template set that produced a new match.
    /// Same-person Face Setup refreshes change this revision but keep the stable
    /// face identity ID, so existing positive matches remain valid.
    public var faceProfileRevision: String {
        let templateIds = faceTemplates
            .map(\.id)
            .filter { !$0.isEmpty }
            .sorted()
        guard !templateIds.isEmpty else { return "" }
        return "v\(faceProfileVersion):\(templateIds.joined(separator: "|"))"
    }

    /// Use one descriptor per distinct enrollment pose. This keeps the
    /// near-threshold corroboration rule honest even if duplicate template
    /// records are ever introduced by migration or malformed remote data.
    public var effectiveEmbeddings: [FaceEmbedding] {
        guard !faceTemplates.isEmpty else { return [faceEmbedding] }
        let distinct = FaceTemplate.distinctPoseEmbeddings(from: faceTemplates)
        return distinct.isEmpty ? [faceEmbedding] : distinct
    }
}
