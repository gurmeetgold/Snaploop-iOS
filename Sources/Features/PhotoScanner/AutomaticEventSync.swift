import BackgroundTasks
import Combine
import Foundation

/// Pure identity helpers for automatic-sync persistence and roster change
/// detection. Kept separate from BGTask/AppEnvironment concerns so account
/// isolation and leave/rejoin semantics can be regression tested directly.
///
/// No phone number, Firebase UID, face embedding, template ID or auth token is
/// written into the UserDefaults key. `sourceInstallationId` is the random,
/// account-scoped identifier produced by AccountInstallationIdentityProviding.
enum AutomaticSyncIdentityScope {
    static func storageKey(prefix: String, sourceInstallationId: String, eventId: String) -> String? {
        let source = sourceInstallationId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return nil }
        return prefix + source + "." + eventId
    }

    static func participantEpoch(_ participant: EventParticipant) -> String {
        if let membershipId = participant.membershipId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !membershipId.isEmpty {
            return membershipId
        }
        // Backward-compatible fallback for legacy members that have not yet been
        // assigned a membershipId. joinedAt changes on leave/rejoin, so it is a
        // safer epoch than stable face identity alone during the migration.
        return "legacy-\(participant.joinedAt.timeIntervalSince1970)"
    }

    static func scanTriggerFingerprint(event: Event, participants: [EventParticipant]) -> String {
        let roster = participants
            .map {
                "\($0.userId)=\(participantEpoch($0))=\($0.stableFaceIdentityId)@\($0.faceProfileRevision)"
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
}

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
    private var sessionGenerationObservation: AnyCancellable?

    private let automaticCooldown: TimeInterval = 60 * 60
    private let backgroundEarliestDelay: TimeInterval = 60 * 60
    private let defaults = UserDefaults.standard
    private let lastRunKeyPrefix = "snaploop.autoSync.lastAttempt."
    private let lastFingerprintKeyPrefix = "snaploop.autoSync.fingerprint."

    private init() {}

    func configure(environment: AppEnvironment, session: AppSession) {
        self.environment = environment
        self.session = session
        sessionGenerationObservation = session.$sessionGeneration
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.cancelForSessionChange()
                }
            }
        // Do not schedule background work blindly. The first foreground eligibility
        // check decides whether there is an Event worth scanning.
    }

    /// Called automatically when the authenticated session generation changes.
    /// Task cancellation is immediate; generation checks below are the second
    /// line of defense for work already between suspension points.
    func cancelForSessionChange() {
        activeRun?.cancel()
        activeRun = nil
        cancelBackgroundProcessing()
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
            let executionContext = session.authenticatedExecutionContext,
            session.faceProfile != nil,
            !ProcessInfo.processInfo.isLowPowerModeEnabled
        else { return false }

        let userId = executionContext.userId
        let sourceInstallationId = environment.accountInstallationIdentity.id(for: userId)
        guard !sourceInstallationId.isEmpty else {
            // Failing closed here is safer than falling back to a Firebase UID in
            // shared local persistence, which could couple two account sessions.
            Log.scanner.error("Automatic scan skipped because source installation identity is unavailable")
            return false
        }

        do {
            let now = Date()
            let loadedEvents = try await environment.events.events(forUserId: userId)
            guard session.isCurrent(executionContext) else { return false }

            let eligibleEvents = loadedEvents.filter { event in
                EventLifecycle.canSync(event, clock: environment.clock, config: environment.config.current)
            }

            guard !eligibleEvents.isEmpty else { return false }

            var hasEligibleSharingEvent = false

            for event in eligibleEvents {
                try Task.checkCancellation()
                guard session.isCurrent(executionContext) else { return false }

                do {
                    let preferences = try await MemberPhotoPreferencesClient.load(eventId: event.id)
                    guard session.isCurrent(executionContext) else { return false }
                    guard preferences.sharingEnabled else { continue }
                    hasEligibleSharingEvent = true

                    // Load the roster before applying the cooldown. A new/rejoined
                    // member or a Face Setup revision changes the fingerprint and
                    // should trigger matching on the next foreground opportunity.
                    let participants = try await EventFaceProfileClient.list(eventId: event.id)
                    try Task.checkCancellation()
                    guard session.isCurrent(executionContext) else { return false }

                    let fingerprint = AutomaticSyncIdentityScope.scanTriggerFingerprint(
                        event: event,
                        participants: participants
                    )
                    let triggerChanged = storedFingerprint(
                        for: event.id,
                        sourceInstallationId: sourceInstallationId
                    ) != fingerprint

                    guard triggerChanged || automaticCooldownElapsed(
                        for: event.id,
                        sourceInstallationId: sourceInstallationId,
                        now: now
                    ) else { continue }
                    markAutomaticAttempt(
                        for: event.id,
                        sourceInstallationId: sourceInstallationId,
                        at: now
                    )

                    // Exactly one coordinator batch per automatic pass. The
                    // coordinator itself applies the device-safety batch cap.
                    _ = try await environment.makeSyncCoordinator().sync(
                        event: event,
                        participants: participants,
                        currentUserId: userId,
                        includeOwnMatches: preferences.includeOwnMatches,
                        preferenceRevision: preferences.revisionToken
                    )
                    guard session.isCurrent(executionContext) else { return false }
                    saveFingerprint(
                        fingerprint,
                        for: event.id,
                        sourceInstallationId: sourceInstallationId
                    )
                } catch is CancellationError {
                    return hasEligibleSharingEvent && session.isCurrent(executionContext)
                } catch {
                    // Automatic discovery must never block the app. Manual
                    // "Scan Event Photos" remains available for visible recovery.
                    Log.scanner.error("Automatic scan skipped Event \(event.id, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }

            return hasEligibleSharingEvent && session.isCurrent(executionContext)
        } catch {
            Log.scanner.error("Automatic Event scan could not load Events: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private func storedFingerprint(for eventId: String, sourceInstallationId: String) -> String? {
        guard let key = AutomaticSyncIdentityScope.storageKey(
            prefix: lastFingerprintKeyPrefix,
            sourceInstallationId: sourceInstallationId,
            eventId: eventId
        ) else { return nil }
        return defaults.string(forKey: key)
    }

    private func saveFingerprint(_ fingerprint: String, for eventId: String, sourceInstallationId: String) {
        guard let key = AutomaticSyncIdentityScope.storageKey(
            prefix: lastFingerprintKeyPrefix,
            sourceInstallationId: sourceInstallationId,
            eventId: eventId
        ) else { return }
        defaults.set(fingerprint, forKey: key)
    }

    private func automaticCooldownElapsed(
        for eventId: String,
        sourceInstallationId: String,
        now: Date
    ) -> Bool {
        guard let key = AutomaticSyncIdentityScope.storageKey(
            prefix: lastRunKeyPrefix,
            sourceInstallationId: sourceInstallationId,
            eventId: eventId
        ) else { return true }
        let last = defaults.double(forKey: key)
        guard last > 0 else { return true }
        return now.timeIntervalSince1970 - last >= automaticCooldown
    }

    private func markAutomaticAttempt(
        for eventId: String,
        sourceInstallationId: String,
        at date: Date
    ) {
        guard let key = AutomaticSyncIdentityScope.storageKey(
            prefix: lastRunKeyPrefix,
            sourceInstallationId: sourceInstallationId,
            eventId: eventId
        ) else { return }
        defaults.set(date.timeIntervalSince1970, forKey: key)
    }
}
