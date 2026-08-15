import Foundation

/// The dependency-injection container for the app. Holds one instance of each
/// service behind its protocol; every feature reads its dependencies from here
/// and never constructs a concrete service itself. This is the single
/// composition point — the one place that knows which implementation is live.
@MainActor
public final class AppEnvironment: ObservableObject {

    public let config: ConfigProviding
    public let clock: Clock
    public let auth: AuthService
    public let photoLibrary: PhotoLibraryService
    public let faceDetection: FaceDetectionService
    public let thumbnailEncoder: ThumbnailEncoder
    public let events: EventRepository
    public let matches: MatchRepository
    public let transfers: TransferRepository
    public let scanStateStore: ScanStateStore
    public let faceProfiles: FaceProfileStore
    public let users: UserDirectory
    public let quality: QualityScoring
    public let analytics: AnalyticsService

    public init(
        config: ConfigProviding,
        clock: Clock,
        auth: AuthService,
        photoLibrary: PhotoLibraryService,
        faceDetection: FaceDetectionService,
        thumbnailEncoder: ThumbnailEncoder,
        events: EventRepository,
        matches: MatchRepository,
        transfers: TransferRepository,
        scanStateStore: ScanStateStore,
        faceProfiles: FaceProfileStore,
        users: UserDirectory,
        quality: QualityScoring,
        analytics: AnalyticsService
    ) {
        self.config = config
        self.clock = clock
        self.auth = auth
        self.photoLibrary = photoLibrary
        self.faceDetection = faceDetection
        self.thumbnailEncoder = thumbnailEncoder
        self.events = events
        self.matches = matches
        self.transfers = transfers
        self.scanStateStore = scanStateStore
        self.faceProfiles = faceProfiles
        self.users = users
        self.quality = quality
        self.analytics = analytics
    }

    /// Builds an erasure service from the current stores.
    public func makeErasureService() -> ErasureService {
        ErasureService(events: events, faceProfiles: faceProfiles, users: users)
    }

    /// A ready-to-run camera-sync coordinator built from the current services.
    public func makeSyncCoordinator() -> CameraSyncCoordinator {
        CameraSyncCoordinator(
            config: config,
            clock: clock,
            photoLibrary: photoLibrary,
            faceDetection: faceDetection,
            thumbnailEncoder: thumbnailEncoder,
            matches: matches,
            scanStateStore: scanStateStore
        )
    }

    /// Dev/preview environment: local + in-memory implementations, no network,
    /// no Firebase, no secrets. This is what the app runs on today. The `.live`
    /// factory that wires Firebase concretes arrives in Phase 2.
    public static func dev() -> AppEnvironment {
        AppEnvironment(
            config: StaticConfigProvider(.default),
            clock: SystemClock(),
            auth: StubAuthService(),
            photoLibrary: StubPhotoLibraryService(),
            faceDetection: StubFaceDetectionService(),
            thumbnailEncoder: PassthroughThumbnailEncoder(),
            events: InMemoryEventRepository(),
            matches: InMemoryMatchRepository(),
            transfers: InMemoryTransferRepository(),
            scanStateStore: InMemoryScanStateStore(),
            faceProfiles: InMemoryFaceProfileStore(),
            users: InMemoryUserDirectory(),
            quality: StubQualityScoring(),
            analytics: InMemoryAnalytics()
        )
    }
}
