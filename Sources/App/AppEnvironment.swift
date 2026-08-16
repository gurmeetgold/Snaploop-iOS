import Foundation

/// The dependency-injection container for the app. Holds one instance of each
/// service behind its protocol; every feature reads its dependencies from here
/// and never constructs a concrete service itself.
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

    public func makeErasureService() -> ErasureService {
        ErasureService(events: events, faceProfiles: faceProfiles, users: users)
    }

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
    /// Whether this run should use real backend services.
    ///
    /// SnapLoop now defaults to LIVE services so normal development and testing
    /// use Firebase automatically.
    ///
    /// To explicitly run against local/in-memory stub services, set:
    ///
    ///     SNAPLOOP_DEV=1
    ///
    /// in the Xcode scheme environment variables.
    public static var useLiveServices: Bool {
        ProcessInfo.processInfo.environment["SNAPLOOP_LIVE"] != "1"
    }

    public static func current() -> AppEnvironment {
        useLiveServices ? .live() : .dev()
    }

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

    /// Live environment. Auth + user directory + private face-profile storage
    /// are now Firebase-backed. Events/matches/transfers remain deliberately
    /// stubbed until their trusted server-side operations are added.
    public static func live() -> AppEnvironment {
        FirebaseBootstrap.configureIfNeeded()
        return AppEnvironment(
            config: StaticConfigProvider(.default),
            clock: SystemClock(),
            auth: FirebaseAuthService(),
            photoLibrary: StubPhotoLibraryService(),
            faceDetection: StubFaceDetectionService(),
            thumbnailEncoder: ImageIOThumbnailEncoder(),
            events: InMemoryEventRepository(),
            matches: InMemoryMatchRepository(),
            transfers: InMemoryTransferRepository(),
            scanStateStore: UserDefaultsScanStateStore(),
            faceProfiles: FirebaseFaceProfileStore(),
            users: FirebaseUserDirectory(),
            quality: StubQualityScoring(),
            analytics: InMemoryAnalytics()
        )
    }
}
