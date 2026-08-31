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
    /// v1 means `startsAt...endsAt` is already the authoritative inclusive
    /// full-calendar-day photo window in `photoWindowTimeZoneId`. Older records
    /// omit the metadata and keep the legacy local-calendar fallback below.
    public static let canonicalPhotoWindowVersion = 1

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

    /// Additive metadata for explicit civil-day semantics. These remain optional
    /// so cached/pre-migration Events decode without data migration or logout.
    public var photoWindowVersion: Int?
    public var photoWindowTimeZoneId: String?
    public var photoWindowStartDayNumber: Int?
    public var photoWindowEndDayNumber: Int?

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
        photoWindowVersion: Int? = nil,
        photoWindowTimeZoneId: String? = nil,
        photoWindowStartDayNumber: Int? = nil,
        photoWindowEndDayNumber: Int? = nil,
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
        self.photoWindowVersion = photoWindowVersion
        self.photoWindowTimeZoneId = photoWindowTimeZoneId
        self.photoWindowStartDayNumber = photoWindowStartDayNumber
        self.photoWindowEndDayNumber = photoWindowEndDayNumber
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    public var photoWindowTimeZone: TimeZone? {
        guard photoWindowVersion == Self.canonicalPhotoWindowVersion,
              let raw = photoWindowTimeZoneId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return TimeZone(identifier: raw)
    }

    /// Event-date editing and display use the timezone in which the organizer's
    /// civil dates were committed, not whichever timezone a participant happens
    /// to be in later.
    public var photoWindowCalendar: Calendar {
        guard let timeZone = photoWindowTimeZone else { return .current }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    public var usesCanonicalPhotoWindow: Bool {
        photoWindowVersion == Self.canonicalPhotoWindowVersion
            && photoWindowTimeZone != nil
            && startsAt <= endsAt
    }

    /// Stable semantic revision for the upcoming photo-corpus/cursor migration.
    /// Day numbers are timezone-independent civil-day ordinals calculated by the
    /// same contract on iOS and the backend.
    public var photoWindowRevision: String {
        if usesCanonicalPhotoWindow,
           let startDay = photoWindowStartDayNumber,
           let endDay = photoWindowEndDayNumber,
           let timeZoneId = photoWindowTimeZoneId {
            return "v\(Self.canonicalPhotoWindowVersion):\(timeZoneId):\(startDay)-\(endDay)"
        }
        return "legacy:\(startsAt.timeIntervalSince1970)-\(endsAt.timeIntervalSince1970)"
    }

    /// New Events persist absolute, complete-day bounds once and every phone uses
    /// those exact instants. Legacy Events retain the previous local expansion so
    /// an app update does not silently narrow an already-existing scan window.
    public var dateRange: ClosedRange<Date> {
        if usesCanonicalPhotoWindow {
            return startsAt...endsAt
        }

        let calendar = Calendar.current
        let lower = calendar.startOfDay(for: startsAt)
        let endStart = calendar.startOfDay(for: endsAt)
        let dayAfterEnd = calendar.date(byAdding: .day, value: 1, to: endStart)
            ?? endStart.addingTimeInterval(86_400)
        let upper = dayAfterEnd.addingTimeInterval(-0.001)
        return lower...max(lower, upper)
    }
}

public struct EventParticipant: Identifiable, Equatable, Codable, Sendable {
    public var id: String { userId }
    public let userId: String
    /// Server-issued event participation generation. It is deliberately
    /// separate from userId and faceIdentityId so leave/rejoin can invalidate
    /// stale matching work without changing account or biometric identity.
    /// Optional only while pre-migration data is still supported.
    public var membershipId: String?
    public var displayName: String?
    public var phoneNumber: String?
    public var faceIdentityId: String?
    public var faceEmbedding: FaceEmbedding
    public var faceTemplates: [FaceTemplate]
    public var faceProfileVersion: Int
    public let joinedAt: Date

    public init(
        userId: String,
        membershipId: String? = nil,
        displayName: String?,
        phoneNumber: String? = nil,
        faceIdentityId: String? = nil,
        faceEmbedding: FaceEmbedding,
        faceTemplates: [FaceTemplate] = [],
        faceProfileVersion: Int,
        joinedAt: Date
    ) {
        self.userId = userId
        self.membershipId = membershipId
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
