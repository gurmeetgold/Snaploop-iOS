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

    /// Whether this run should use real backend services where they exist yet.
    /// Toggle by setting the `SNAPLOOP_LIVE=1` environment variable on the
    /// Xcode scheme (Product ▸ Scheme ▸ Edit Scheme ▸ Run ▸ Arguments) — no
    /// code edits needed, and each newly-wired seam in `.live()` becomes
    /// testable the moment you flip it on. Defaults to false so a fresh
    /// checkout always just runs, with zero credentials.
    public static var useLiveServices: Bool {
        ProcessInfo.processInfo.environment["SNAPLOOP_LIVE"] == "1"
    }

    /// Picks `.live()` or `.dev()` based on `useLiveServices`. This is what
    /// `SnapLoopApp` constructs its environment from.
    public static func current() -> AppEnvironment {
        useLiveServices ? .live() : .dev()
    }

    /// Dev/preview environment: local + in-memory implementations, no network,
    /// no Firebase, no secrets. This is what the app runs on by default.
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

    /// Live environment. Wired incrementally, one seam at a time, so each is
    /// independently testable before the next depends on it:
    ///
    ///   ✅ auth              — `FirebaseAuthService` (Firebase Auth, phone/OTP)
    ///   ⬜ users              — next: Firestore-backed `UserDirectory`
    ///   ⬜ faceProfiles       — next: Firestore-backed `FaceProfileStore`
    ///   ⬜ events             — after that: Firestore-backed `EventRepository`
    ///   ⬜ matches, transfers — after that: Firestore + Storage
    ///   ⬜ config             — later, low priority: Firebase Remote Config
    ///
    /// `photoLibrary`, `faceDetection`, and `quality` are **not** part of this
    /// list — they're on-device PhotoKit/Vision/Core ML work, unrelated to
    /// Firebase, and land as their own separate track.
    ///
    /// Until a row above is checked off, that seam stays on its `.dev()`
    /// in-memory/stub implementation here — signing in via `auth` proves
    /// identity but doesn't yet persist a profile beyond Firebase Auth's own
    /// user record.
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
            faceProfiles: InMemoryFaceProfileStore(),
            users: InMemoryUserDirectory(),
            quality: StubQualityScoring(),
            analytics: InMemoryAnalytics()
        )
    }
}
