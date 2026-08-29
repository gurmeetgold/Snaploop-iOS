import BackgroundTasks
import Foundation

/// Resource-conscious, best-effort automatic photo discovery for Events whose
/// photo window is still open.
///
/// Automatic work is intentionally conservative:
/// - no eligible Event -> no photo scan and no background task is kept scheduled
/// - sharing off -> that Event is skipped
/// - unchanged Events have a persistent one-hour automatic-scan cooldown
/// - roster/date changes bypass that cooldown on the next foreground opportunity
/// - only one bounded coordinator batch is processed per automatic pass
/// - Low Power Mode skips automatic scanning entirely
///
/// Manual "Scan Event Photos" is separate and is never blocked by this cooldown.
@MainActor
final class AutomaticEventSync {
    static let shared = AutomaticEventSync()
    static let backgroundTaskIdentifier = "com.gurmeetchhiber.snaploop.app.event-photo-sync"

    private weak var environment: AppEnvironment?
    private weak var session: AppSession?
    private var activeRun: Task<Void, Never>?

    private let automaticCooldown: TimeInterval = 60 * 60
    private let backgroundEarliestDelay: TimeInterval = 60 * 60
    private let defaults = UserDefaults.standard
    private let lastRunKeyPrefix = "snaploop.autoSync.lastAttempt."
    private let lastFingerprintKeyPrefix = "snaploop.autoSync.fingerprint."

    private init() {}

    func configure(environment: AppEnvironment, session: AppSession) {
        self.environment = environment
        self.session = session
        // Do not schedule background work blindly. The first foreground eligibility
        // check decides whether there is an Event worth scanning.
    }

    func runWhenAppBecomesActive() {
        guard activeRun == nil else { return }
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else {
            cancelBackgroundProcessing()
            return
        }

        activeRun = Task { [weak self] in
            guard let self else { return }
            let hasEligibleEvent = await self.runIncrementalPasses()
            self.activeRun = nil
            self.updateBackgroundSchedule(hasEligibleEvent: hasEligibleEvent)
        }
    }

    func handleBackgroundProcessing(_ task: BGProcessingTask) {
        guard
            environment != nil,
            session?.user != nil,
            !ProcessInfo.processInfo.isLowPowerModeEnabled
        else {
            cancelBackgroundProcessing()
            task.setTaskCompleted(success: true)
            return
        }

        let work = Task { [weak self] in
            guard let self else {
                task.setTaskCompleted(success: false)
                return
            }
            let hasEligibleEvent = await self.runIncrementalPasses()
            self.updateBackgroundSchedule(hasEligibleEvent: hasEligibleEvent)
            task.setTaskCompleted(success: !Task.isCancelled)
        }
        task.expirationHandler = { work.cancel() }
    }

    private func updateBackgroundSchedule(hasEligibleEvent: Bool) {
        guard hasEligibleEvent else {
            cancelBackgroundProcessing()
            return
        }
        scheduleBackgroundProcessing()
    }

    private func scheduleBackgroundProcessing() {
        guard AppEnvironment.useLiveServices else { return }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundTaskIdentifier)

        let request = BGProcessingTaskRequest(identifier: Self.backgroundTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: backgroundEarliestDelay)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Log.scanner.error("Could not schedule automatic Event scan: \(String(describing: error), privacy: .public)")
        }
    }

    private func cancelBackgroundProcessing() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundTaskIdentifier)
    }

    /// Returns true only when at least one Event is still inside its photo
    /// recovery window and has sharing enabled. That result controls whether
    /// another background task should be scheduled.
    private func runIncrementalPasses() async -> Bool {
        guard
            AppEnvironment.useLiveServices,
            let environment,
            let session,
            let userId = session.user?.id,
            session.faceProfile != nil,
            !ProcessInfo.processInfo.isLowPowerModeEnabled
        else { return false }

        do {
            let now = Date()
            let eligibleEvents = try await environment.events.events(forUserId: userId)
                .filter { event in
                    EventLifecycle.canSync(event, clock: environment.clock, config: environment.config.current)
                }

            guard !eligibleEvents.isEmpty else { return false }

            var hasEligibleSharingEvent = false

            for event in eligibleEvents {
                try Task.checkCancellation()
                do {
                    let preferences = try await MemberPhotoPreferencesClient.load(eventId: event.id)
                    guard preferences.sharingEnabled else { continue }
                    hasEligibleSharingEvent = true

                    // Load the roster before applying the cooldown. A new/rejoined
                    // member changes the fingerprint and should trigger a fresh
                    // matching pass the next time this iPhone is active, rather
                    // than waiting up to an hour.
                    let participants = try await EventFaceProfileClient.list(eventId: event.id)
                    try Task.checkCancellation()
                    let fingerprint = scanTriggerFingerprint(event: event, participants: participants)
                    let triggerChanged = storedFingerprint(for: event.id) != fingerprint

                    guard triggerChanged || automaticCooldownElapsed(for: event.id, now: now) else { continue }
                    markAutomaticAttempt(for: event.id, at: now)

                    // Exactly one coordinator batch per automatic pass. The
                    // coordinator itself applies the device-safety batch cap.
                    _ = try await environment.makeSyncCoordinator().sync(
                        event: event,
                        participants: participants,
                        currentUserId: userId,
                        includeOwnMatches: preferences.includeOwnMatches,
                        preferenceRevision: preferences.revisionToken
                    )
                    saveFingerprint(fingerprint, for: event.id)
                } catch is CancellationError {
                    return hasEligibleSharingEvent
                } catch {
                    // Automatic discovery must never block the app. Manual
                    // "Scan Event Photos" remains available for visible recovery.
                    Log.scanner.error("Automatic scan skipped Event \(event.id, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }

            return hasEligibleSharingEvent
        } catch {
            Log.scanner.error("Automatic Event scan could not load Events: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private func scanTriggerFingerprint(event: Event, participants: [EventParticipant]) -> String {
        let roster = participants
            .map {
                "\($0.userId)=\($0.stableFaceIdentityId)@\($0.joinedAt.timeIntervalSince1970)"
            }
            .sorted()
            .joined(separator: ";")
        return [
            String(event.updatedAt.timeIntervalSince1970),
            String(event.startsAt.timeIntervalSince1970),
            String(event.endsAt.timeIntervalSince1970),
            roster,
        ].joined(separator: "::")
    }

    private func storedFingerprint(for eventId: String) -> String? {
        defaults.string(forKey: lastFingerprintKeyPrefix + eventId)
    }

    private func saveFingerprint(_ fingerprint: String, for eventId: String) {
        defaults.set(fingerprint, forKey: lastFingerprintKeyPrefix + eventId)
    }

    private func automaticCooldownElapsed(for eventId: String, now: Date) -> Bool {
        let key = lastRunKeyPrefix + eventId
        let last = defaults.double(forKey: key)
        guard last > 0 else { return true }
        return now.timeIntervalSince1970 - last >= automaticCooldown
    }

    private func markAutomaticAttempt(for eventId: String, at date: Date) {
        defaults.set(date.timeIntervalSince1970, forKey: lastRunKeyPrefix + eventId)
    }
}
