import Foundation

/// Lightweight, in-memory stand-ins so the app compiles and renders its screens
/// before the Firebase/Vision concretes exist (Phase 2). These are DEV ONLY —
/// they never ship in a release build and hold no secrets. Each returns empty
/// or trivially-shaped data so empty states are exercisable in the simulator.
enum Dev {}

final class StubAuthService: AuthService, @unchecked Sendable {
    private(set) var currentUserId: String?
    init(signedInAs userId: String? = nil) { self.currentUserId = userId }
    func startPhoneVerification(phoneNumber: String) async throws -> String { "dev-verification" }
    func confirmVerification(verificationId: String, code: String) async throws -> String {
        let id = "dev-user"; currentUserId = id; return id
    }
    func signOut() throws { currentUserId = nil }
}

struct StubPhotoLibraryService: PhotoLibraryService {
    func authorizationStatus() -> PhotoAuthorization { .authorized }
    func requestAuthorization() async -> PhotoAuthorization { .authorized }
    func assets(in range: ClosedRange<Date>) async throws -> [PhotoAsset] { [] }
    func imageData(for assetId: String, maxPixelSize: Int) async throws -> Data { Data() }
    func originalImageData(for assetId: String) async throws -> Data { Data() }
}

struct StubFaceDetectionService: FaceDetectionService {
    func detectFaces(in imageData: Data) async throws -> [DetectedFace] { [] }
    func embeddingForSelfie(_ imageData: Data) async throws -> FaceEmbedding {
        FaceEmbedding(normalized: [1, 0, 0])
    }
}

struct PassthroughThumbnailEncoder: ThumbnailEncoder {
    func encodeJPEG(from imageData: Data, maxPixelSize: Int, quality: Double) throws -> Data { imageData }
}

final class InMemoryEventRepository: EventRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String: Event] = [:]
    private var roster: [String: [EventParticipant]] = [:]
    private var membership: [String: [String: EventMember]] = [:]   // eventId -> userId -> member

    func createEvent(_ event: Event) async throws {
        lock.lock(); events[event.id] = event; lock.unlock()
    }
    func fetchEvent(id: String) async throws -> Event {
        lock.lock(); defer { lock.unlock() }
        guard let e = events[id] else { throw AppError.eventNotFound }; return e
    }
    func fetchEvent(joinCode: JoinCode) async throws -> Event {
        lock.lock(); defer { lock.unlock() }
        guard let e = events.values.first(where: { $0.joinCode == joinCode.value })
        else { throw AppError.invalidJoinCode }; return e
    }
    func fetchEvent(inviteToken: InviteToken) async throws -> Event {
        lock.lock(); defer { lock.unlock() }
        guard let e = events.values.first(where: { $0.inviteToken == inviteToken.value })
        else { throw AppError.eventNotFound }; return e
    }
    func updateEventDetails(id: String, name: String, category: EventCategory, coverImagePath: String?, locationName: String?) async throws {
        lock.lock(); defer { lock.unlock() }
        guard var e = events[id] else { throw AppError.eventNotFound }
        e.name = name; e.category = category; e.coverImagePath = coverImagePath
        e.locationName = locationName; e.updatedAt = Date()
        events[id] = e   // identity fields untouched, by contract
    }
    func updateEventDates(id: String, startsAt: Date, endsAt: Date) async throws {
        lock.lock(); defer { lock.unlock() }
        guard var e = events[id] else { throw AppError.eventNotFound }
        e.startsAt = startsAt; e.endsAt = endsAt; e.updatedAt = Date()
        events[id] = e
    }
    func endEvent(id: String) async throws {
        lock.lock(); defer { lock.unlock() }
        guard var e = events[id] else { throw AppError.eventNotFound }
        e.status = .endedByOrganizer; e.updatedAt = Date(); events[id] = e
    }
    func addMember(eventId: String, member: EventMember) async throws {
        lock.lock(); membership[eventId, default: [:]][member.userId] = member; lock.unlock()
    }
    func removeMember(eventId: String, userId: String) async throws {
        lock.lock()
        membership[eventId]?[userId] = nil
        roster[eventId]?.removeAll { $0.userId == userId }   // revoke embedding
        lock.unlock()
    }
    func setSharing(eventId: String, userId: String, enabled: Bool) async throws {
        lock.lock(); defer { lock.unlock() }
        guard var m = membership[eventId]?[userId] else { throw AppError.notAMember }
        m.sharingEnabled = enabled; membership[eventId]?[userId] = m
    }
    func members(eventId: String) async throws -> [EventMember] {
        lock.lock(); defer { lock.unlock() }
        return Array((membership[eventId] ?? [:]).values).sorted { $0.joinedAt < $1.joinedAt }
    }
    func join(eventId: String, participant: EventParticipant) async throws {
        lock.lock()
        roster[eventId, default: []].removeAll { $0.userId == participant.userId }
        roster[eventId, default: []].append(participant)
        lock.unlock()
    }
    func participants(eventId: String) async throws -> [EventParticipant] {
        lock.lock(); defer { lock.unlock() }; return roster[eventId] ?? []
    }
    func events(forUserId userId: String) async throws -> [Event] {
        lock.lock(); defer { lock.unlock() }
        return events.values
            .filter { membership[$0.id]?[userId] != nil }
            .sorted { $0.startsAt > $1.startsAt }
    }
}

final class InMemoryMatchRepository: MatchRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: PhotoMatch] = [:]

    func upload(match: PhotoMatch, thumbnailJPEG: Data) async throws {
        lock.lock(); store[match.id] = match; lock.unlock()
    }
    func dismissAppearance(matchId: String, participantUserId: String) async throws {
        lock.lock(); defer { lock.unlock() }
        guard var m = store[matchId] else { return }
        m.appearances = m.appearances.map {
            var a = $0
            if a.participantUserId == participantUserId { a.dismissedByUser = true }
            return a
        }
        store[matchId] = m
    }
    func myPhotos(eventId: String, userId: String) async throws -> [PhotoMatch] {
        lock.lock(); defer { lock.unlock() }
        return store.values
            .filter { $0.eventId == eventId && $0.activeParticipantIds.contains(userId) }
            .sorted { $0.capturedAt > $1.capturedAt }
    }
    func sharedAlbum(eventId: String) async throws -> [PhotoMatch] {
        lock.lock(); defer { lock.unlock() }
        return store.values.filter { $0.eventId == eventId }.sorted { $0.capturedAt > $1.capturedAt }
    }
    func signedOriginalURL(match: PhotoMatch, ttlHours: Int) async throws -> URL {
        URL(string: "https://example.invalid/original/\(match.id)")!
    }
}
