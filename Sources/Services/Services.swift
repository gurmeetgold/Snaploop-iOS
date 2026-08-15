import Foundation

// MARK: - Authentication

/// Phone-number + OTP authentication. Backed by Firebase Auth in production.
public protocol AuthService: Sendable {
    var currentUserId: String? { get }
    /// Sends an OTP to the given E.164 number; returns an opaque verification id.
    func startPhoneVerification(phoneNumber: String) async throws -> String
    /// Confirms the code for a verification id and returns the signed-in user id.
    func confirmVerification(verificationId: String, code: String) async throws -> String
    func signOut() throws
}

// MARK: - Remote Config

/// Supplies the app's tunables. Production implementation wraps Firebase Remote
/// Config; both always resolve to a fully-populated `RemoteConfigValues`.
public protocol ConfigProviding: Sendable {
    /// The most recently fetched values (never partial — missing keys fall back
    /// to `RemoteConfigValues.default`).
    var current: RemoteConfigValues { get }
    /// Fetches and activates the latest values. Safe to call repeatedly.
    func refresh() async
}

// MARK: - Photo library

/// Read-only access to *this device's own* photo library. Never another user's.
public protocol PhotoLibraryService: Sendable {
    /// Whether the app currently has (at least limited) library access.
    func authorizationStatus() -> PhotoAuthorization
    /// Requests access, returning the resulting status.
    func requestAuthorization() async -> PhotoAuthorization
    /// All image assets whose creation date is within `range` (metadata only —
    /// no pixels loaded). Used by the planner.
    func assets(in range: ClosedRange<Date>) async throws -> [PhotoAsset]
    /// Loads image data for one asset at up to `maxPixelSize` on the long edge
    /// (used both for on-device detection and for thumbnail generation).
    func imageData(for assetId: String, maxPixelSize: Int) async throws -> Data
    /// Loads the full-resolution original for on-demand download/export.
    func originalImageData(for assetId: String) async throws -> Data
}

public enum PhotoAuthorization: Equatable, Sendable {
    case authorized      // full access
    case limited         // limited-library access (still usable)
    case denied
    case notDetermined
    /// Whether we can scan at all.
    public var canRead: Bool { self == .authorized || self == .limited }
}

// MARK: - Face detection + embedding (on-device)

/// On-device face pipeline: Vision for detection + a Core ML model for
/// embeddings. Runs entirely on the device — never a cloud vision/LLM call.
public protocol FaceDetectionService: Sendable {
    /// Detects faces in image data and returns an embedding + size for each.
    func detectFaces(in imageData: Data) async throws -> [DetectedFace]
    /// Produces a single embedding from a selfie for the user's face profile.
    /// Throws if zero or multiple faces are present (profile must be one person).
    func embeddingForSelfie(_ imageData: Data) async throws -> FaceEmbedding
}

// MARK: - Event data

/// Event + roster persistence. Backed by Firestore in production.
public protocol EventRepository: Sendable {
    func createEvent(_ event: Event) async throws
    func fetchEvent(id: String) async throws -> Event
    func fetchEvent(joinCode: JoinCode) async throws -> Event
    func fetchEvent(inviteToken: InviteToken) async throws -> Event

    /// Edits presentation details only — identity fields are immutable and not
    /// part of this call, by design.
    func updateEventDetails(id: String, name: String, category: EventCategory, coverImagePath: String?, locationName: String?) async throws
    /// Edits the date window without touching the invite link.
    func updateEventDates(id: String, startsAt: Date, endsAt: Date) async throws
    /// Marks an event ended by the organizer (early "End Event").
    func endEvent(id: String) async throws

    // Membership (the doc whose existence grants read access).
    func addMember(eventId: String, member: EventMember) async throws
    func removeMember(eventId: String, userId: String) async throws
    func setSharing(eventId: String, userId: String, enabled: Bool) async throws
    func members(eventId: String) async throws -> [EventMember]

    // Matching roster (embeddings, downloaded only for this event's members).
    func join(eventId: String, participant: EventParticipant) async throws
    func participants(eventId: String) async throws -> [EventParticipant]

    /// Events the user is a member of (drives Home/Events).
    func events(forUserId userId: String) async throws -> [Event]
}

// MARK: - Matches + thumbnails

/// Upload/fetch of match metadata and thumbnails, and minting of on-demand
/// signed URLs for originals. Firestore + Firebase Storage in production.
public protocol MatchRepository: Sendable {
    /// Uploads a matched photo's thumbnail and metadata.
    func upload(match: PhotoMatch, thumbnailJPEG: Data) async throws
    /// Records a user's "Not Me" correction for a match.
    func dismissAppearance(matchId: String, participantUserId: String) async throws
    /// A participant's personal feed — photos they appear in and haven't dismissed.
    func myPhotos(eventId: String, userId: String) async throws -> [PhotoMatch]
    /// The full shared album for an event.
    func sharedAlbum(eventId: String) async throws -> [PhotoMatch]
    /// A short-lived signed URL to download an original on demand.
    func signedOriginalURL(match: PhotoMatch, ttlHours: Int) async throws -> URL
}

// MARK: - Transfers (on-demand originals)

/// Client-side access to transfer jobs. The trusted state-machine transitions
/// happen server-side (Cloud Functions); the client requests, watches, and
/// downloads. Backed by Firestore `transfers/{transferId}` in production.
public protocol TransferRepository: Sendable {
    /// Requests an original. Idempotent — a repeat call for the same photo by
    /// the same requester returns the existing job rather than duplicating work.
    func requestTransfer(eventId: String, photo: PhotoMatch, requestingUserId: String) async throws -> TransferJob
    /// Jobs where the current user is the requester (their downloads) or the
    /// source (originals others are waiting on from their phone).
    func transfers(involvingUserId: String) async throws -> [TransferJob]
}

// MARK: - Face profile store

/// Persists the user's own `FaceProfile` (the sensitive reference embedding).
/// Deleting here removes the biometric template entirely.
public protocol FaceProfileStore: Sendable {
    func load(userId: String) async throws -> FaceProfile?
    func save(_ profile: FaceProfile) async throws
    func delete(userId: String) async throws
}

// MARK: - User directory

/// User document CRUD. Backed by Firestore `users/{uid}` in production.
public protocol UserDirectory: Sendable {
    func fetch(userId: String) async throws -> User
    func save(_ user: User) async throws
    func delete(userId: String) async throws
}

// MARK: - Local scan state

/// Persists per-event `ScanState` locally so sync stays incremental across app
/// launches. Local only — the device tracks only its own scanning.
public protocol ScanStateStore: Sendable {
    func load(eventId: String) -> ScanState
    func save(_ state: ScanState)
}
