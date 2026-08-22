import Foundation

/// The dependency-injection container for SnapLoop.
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
    public let biometricConsent: BiometricConsentStore
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
        biometricConsent: BiometricConsentStore,
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
        self.biometricConsent = biometricConsent
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

    public static var useLiveServices: Bool {
        ProcessInfo.processInfo.environment["SNAPLOOP_DEV"] != "1"
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
            biometricConsent: InMemoryBiometricConsentStore(),
            users: InMemoryUserDirectory(),
            quality: StubQualityScoring(),
            analytics: InMemoryAnalytics()
        )
    }

    public static func live() -> AppEnvironment {
        FirebaseBootstrap.configureIfNeeded()

        // Keep first launch responsive. The Core ML model is loaded only when
        // Face Setup or camera matching actually needs it.
        let faceService: FaceDetectionService = LazyFaceDetectionService()

        return AppEnvironment(
            config: FirebaseRemoteConfigProvider(),
            clock: SystemClock(),
            auth: FirebaseAuthService(),
            photoLibrary: PhotoKitPhotoLibraryService(),
            faceDetection: faceService,
            thumbnailEncoder: ImageIOThumbnailEncoder(),
            events: FirebaseEventRepository(),
            matches: FirebaseMatchRepository(),
            transfers: InMemoryTransferRepository(),
            scanStateStore: UserDefaultsScanStateStore(),
            faceProfiles: FirebaseFaceProfileStore(),
            biometricConsent: FirebaseBiometricConsentStore(),
            users: FirebaseUserDirectory(),
            quality: StubQualityScoring(),
            analytics: InMemoryAnalytics()
        )
    }
}
