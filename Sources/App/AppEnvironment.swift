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
    public let accountInstallationIdentity: AccountInstallationIdentityProviding

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
        analytics: AnalyticsService,
        accountInstallationIdentity: AccountInstallationIdentityProviding = InMemoryAccountInstallationIdentityStore()
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
        self.accountInstallationIdentity = accountInstallationIdentity
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
            analytics: InMemoryAnalytics(),
            accountInstallationIdentity: InMemoryAccountInstallationIdentityStore()
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
            analytics: InMemoryAnalytics(),
            accountInstallationIdentity: SecureAccountInstallationIdentityStore()
        )
    }
}

/// Defers Core ML model loading until face matching is actually used. A fresh
/// install may need extra time to prepare the model; doing that before SwiftUI
/// presents the first screen can otherwise look like a blank launch.
public final class LazyFaceDetectionService: FaceDetectionService, FaceDiagnosticsProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var cached: FaceDetectionService?

    public init() {}

    private func service() -> FaceDetectionService {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let created = PipelineFaceDetectionService.makeDefault()
        cached = created
        return created
    }

    public var isReadyForMatching: Bool { service().isReadyForMatching }
    public var engineIdentifier: String { service().engineIdentifier }
    public var modelVersion: Int { service().modelVersion }

    public func detectFaces(in imageData: Data) async throws -> [DetectedFace] {
        try await service().detectFaces(in: imageData)
    }

    public func embeddingForSelfie(_ imageData: Data) async throws -> FaceEmbedding {
        try await service().embeddingForSelfie(imageData)
    }

    public func diagnose(in imageData: Data) async throws -> FacePipelineDiagnostics {
        let resolved = service()
        guard let diagnosticService = resolved as? FaceDiagnosticsProviding else {
            throw AppError.faceRecognitionNotReady
        }
        return try await diagnosticService.diagnose(in: imageData)
    }
}
