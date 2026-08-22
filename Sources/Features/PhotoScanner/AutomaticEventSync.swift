import BackgroundTasks
import Foundation

/// Best-effort automatic photo discovery for live Events.
///
/// iOS does not guarantee when background work runs. SnapLoop therefore runs a
/// lightweight incremental pass whenever the signed-in app becomes active and
/// also requests BGProcessing time for additional opportunistic passes.
@MainActor
final class AutomaticEventSync {
    static let shared = AutomaticEventSync()
    static let backgroundTaskIdentifier = "com.gurmeetchhiber.snaploop.app.event-photo-sync"

    private weak var environment: AppEnvironment?
    private weak var session: AppSession?
    private var activeRun: Task<Void, Never>?
    private var lastForegroundRun: Date?
    private let foregroundThrottle: TimeInterval = 5 * 60

    private init() {}

    func configure(environment: AppEnvironment, session: AppSession) {
        self.environment = environment
        self.session = session
        scheduleBackgroundProcessing()
    }

    func runWhenAppBecomesActive() {
        guard activeRun == nil else { return }
        if let lastForegroundRun, Date().timeIntervalSince(lastForegroundRun) < foregroundThrottle {
            return
        }
        lastForegroundRun = Date()
        activeRun = Task { [weak self] in
            guard let self else { return }
            await self.runIncrementalPasses(maxBatchesPerEvent: 2)
            self.activeRun = nil
            self.scheduleBackgroundProcessing()
        }
    }

    func handleBackgroundProcessing(_ task: BGProcessingTask) {
        scheduleBackgroundProcessing()

        guard environment != nil, session?.user != nil else {
            task.setTaskCompleted(success: true)
            return
        }

        let work = Task { [weak self] in
            guard let self else {
                task.setTaskCompleted(success: false)
                return
            }
            await self.runIncrementalPasses(maxBatchesPerEvent: 2)
            task.setTaskCompleted(success: !Task.isCancelled)
        }
        task.expirationHandler = { work.cancel() }
    }

    func scheduleBackgroundProcessing() {
        guard AppEnvironment.useLiveServices else { return }
        let request = BGProcessingTaskRequest(identifier: Self.backgroundTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Log.scanner.error("Could not schedule automatic Event sync: \(String(describing: error), privacy: .public)")
        }
    }

    private func runIncrementalPasses(maxBatchesPerEvent: Int) async {
        guard
            AppEnvironment.useLiveServices,
            let environment,
            let session,
            let userId = session.user?.id,
            session.faceProfile != nil
        else { return }

        do {
            let now = Date()
            let events = try await environment.events.events(forUserId: userId)
                .filter { event in
                    event.status == .active && event.startsAt <= now && event.endsAt >= now
                }

            for event in events {
                try Task.checkCancellation()
                do {
                    let preferences = try await MemberPhotoPreferencesClient.load(eventId: event.id)
                    guard preferences.sharingEnabled else { continue }
                    let participants = try await EventFaceProfileClient.list(eventId: event.id)

                    for _ in 0..<maxBatchesPerEvent {
                        try Task.checkCancellation()
                        let summary = try await environment.makeSyncCoordinator().sync(
                            event: event,
                            participants: participants,
                            currentUserId: userId,
                            includeOwnMatches: preferences.includeOwnMatches,
                            preferenceRevision: preferences.revisionToken
                        )
                        if !summary.hasMore { break }
                    }
                } catch is CancellationError {
                    return
                } catch {
                    // Automatic discovery must never block the app. Manual
                    // "Sync My Camera" remains available for visible recovery.
                    Log.scanner.error("Automatic sync skipped Event \(event.id, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
        } catch {
            Log.scanner.error("Automatic Event sync could not load Events: \(String(describing: error), privacy: .public)")
        }
    }
}
