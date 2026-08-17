import Foundation

public protocol AuthService: Sendable {
    var currentUserId: String? { get }
    func startPhoneVerification(phoneNumber: String) async throws -> String
    func confirmVerification(verificationId: String, code: String) async throws -> String
    func signOut() throws
}

public protocol ConfigProviding: Sendable {
    var current: RemoteConfigValues { get }
    func refresh() async
}

public protocol PhotoLibraryService: Sendable {
    func authorizationStatus() -> PhotoAuthorization
    func requestAuthorization() async -> PhotoAuthorization
    func assets(in range: ClosedRange<Date>) async throws -> [PhotoAsset]
    func imageData(for assetId: String, maxPixelSize: Int) async throws -> Data
    func originalImageData(for assetId: String) async throws -> Data
}

public enum PhotoAuthorization: Equatable, Sendable {
    case authorized, limited, denied, notDetermined
    public var canRead: Bool { self == .authorized || self == .limited }
}

public protocol FaceDetectionService: Sendable {
    var isReadyForMatching: Bool { get }
    var engineIdentifier: String { get }
    var modelVersion: Int { get }
    func detectFaces(in imageData: Data) async throws -> [DetectedFace]
    func embeddingForSelfie(_ imageData: Data) async throws -> FaceEmbedding
}

public extension FaceDetectionService {
    var isReadyForMatching: Bool { true }
    var engineIdentifier: String { "unknown" }
    var modelVersion: Int { 0 }
}

public protocol EventRepository: Sendable {
    func createEvent(_ event: Event) async throws
    func fetchEvent(id: String) async throws -> Event
    func fetchEvent(joinCode: JoinCode) async throws -> Event
    func fetchEvent(inviteToken: InviteToken) async throws -> Event
    func updateEventDetails(id: String, name: String, category: EventCategory, coverImagePath: String?, locationName: String?) async throws
    func updateEventDates(id: String, startsAt: Date, endsAt: Date) async throws
    func endEvent(id: String) async throws
    func archiveEvent(id: String) async throws
    func restoreEvent(id: String) async throws
    func addMember(eventId: String, member: EventMember) async throws
    func removeMember(eventId: String, userId: String) async throws
    func setSharing(eventId: String, userId: String, enabled: Bool) async throws
    func members(eventId: String) async throws -> [EventMember]
    func join(eventId: String, participant: EventParticipant) async throws
    func participants(eventId: String) async throws -> [EventParticipant]
    func events(forUserId userId: String) async throws -> [Event]
}

public protocol MatchRepository: Sendable {
    func upload(match: PhotoMatch, thumbnailJPEG: Data) async throws
    func dismissAppearance(matchId: String, participantUserId: String) async throws
    func myPhotos(eventId: String, userId: String) async throws -> [PhotoMatch]
    func sharedAlbum(eventId: String) async throws -> [PhotoMatch]
    func signedOriginalURL(match: PhotoMatch, ttlHours: Int) async throws -> URL
}

public protocol TransferRepository: Sendable {
    func requestTransfer(eventId: String, photo: PhotoMatch, requestingUserId: String) async throws -> TransferJob
    func transfers(involvingUserId: String) async throws -> [TransferJob]
}

public protocol FaceProfileStore: Sendable {
    func load(userId: String) async throws -> FaceProfile?
    func save(_ profile: FaceProfile) async throws
    func delete(userId: String) async throws
}

public protocol UserDirectory: Sendable {
    func fetch(userId: String) async throws -> User
    func save(_ user: User) async throws
    func delete(userId: String) async throws
}

public protocol ScanStateStore: Sendable {
    func load(eventId: String) -> ScanState
    func save(_ state: ScanState)
}

public protocol BiometricConsentStore: Sendable {
    func load(userId: String) async throws -> BiometricConsentRecord?
    func save(_ record: BiometricConsentRecord) async throws
    func withdraw(userId: String, at date: Date) async throws
}
