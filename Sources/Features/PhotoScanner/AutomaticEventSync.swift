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

    static func scanTriggerFingerprint(
        event: Event,
        participants: [EventParticipant],
        sourceMembershipId: String? = nil,
        sharingRevision: String? = nil
    ) -> String {
        let roster = participants
            .map {
                "\($0.userId)=\(participantEpoch($0))=\($0.stableFaceIdentityId)@\($0.faceProfileRevision)"
            }
            .sorted()
            .joined(separator: ";")
        let sourceMembership = sourceMembershipId?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sharing = sharingRevision?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return [
            String(event.updatedAt.timeIntervalSince1970),
            String(event.startsAt.timeIntervalSince1970),
            String(event.endsAt.timeIntervalSince1970),
            "source=\(sourceMembership)",
            "sharing=\(sharing)",
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
/// - roster/date/membership/sharing-generation changes bypass that cooldown
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
            !ProcessInfo.processInfo.isLowPowerModeEnabled
        else { return false }

        // A source user's own Face Setup is intentionally not a prerequisite for
        // contributing photos. Event membership + per-device sharing preference
        // authorize source behavior; the current biometric roster independently
        // decides who can receive matches. This also lets automatic sharing keep
        // working if the source deletes/refreshes their own Face Setup mid-Event.
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

                    // Load the trusted manifest before applying the cooldown. A
                    // roster/template update, source leave/rejoin, or sharing
                    // OFF→ON generation change must run on the next opportunity.
                    let manifest = try await EventFaceProfileClient.manifest(eventId: event.id)
                    try Task.checkCancellation()
                    guard session.isCurrent(executionContext) else { return false }

                    let fingerprint = AutomaticSyncIdentityScope.scanTriggerFingerprint(
                        event: event,
                        participants: manifest.participants,
                        sourceMembershipId: manifest.sourceMembershipId,
                        sharingRevision: preferences.revisionToken
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
                    environment.analytics.log(.scanStarted(source: .automatic))
                    let summary = try await environment.makeSyncCoordinator().sync(
                        event: event,
                        participants: manifest.participants,
                        currentUserId: userId,
                        sourceMembershipId: manifest.sourceMembershipId,
                        includeOwnMatches: preferences.includeOwnMatches,
                        preferenceRevision: preferences.revisionToken
                    )
                    guard session.isCurrent(executionContext) else { return false }

                    if summary.hasRetryableFailures {
                        environment.analytics.log(.scanFailed(
                            source: .automatic,
                            reason: .retryableWork
                        ))
                    } else {
                        environment.analytics.log(.scanCompleted(
                            source: .automatic,
                            scanned: summary.scanned,
                            matchedPhotos: summary.matchedPhotos,
                            remaining: summary.remaining,
                            alreadyCaughtUp: summary.alreadyCaughtUp
                        ))
                        if summary.scanned > 0 && summary.matchedPhotos == 0 {
                            environment.analytics.log(.zeroMatchScanCompleted(
                                source: .automatic,
                                scanned: summary.scanned
                            ))
                        }
                    }

                    // Never record a failed pass as synchronized. The old code
                    // saved the roster fingerprint even when every publication
                    // failed, which suppressed automatic recovery until the next
                    // cooldown. Failed assets remain pending and should retry on
                    // the next eligible foreground/background opportunity.
                    if summary.hasRetryableFailures {
                        Log.scanner.error(
                            "Automatic scan left retryable photo work pending count=\(summary.remaining, privacy: .public)"
                        )
                        continue
                    }

                    saveFingerprint(
                        fingerprint,
                        for: event.id,
                        sourceInstallationId: sourceInstallationId
                    )
                } catch is CancellationError {
                    environment.analytics.log(.scanInterrupted(reason: .systemCancellation))
                    return hasEligibleSharingEvent && session.isCurrent(executionContext)
                } catch is AppError {
                    environment.analytics.log(.scanFailed(source: .automatic, reason: .appError))
                    FirebaseObservability.recordNonFatal(code: "automatic_scan_app_error")
                    // Automatic discovery must never block the app. Manual
                    // "Scan Event Photos" remains available for visible recovery.
                    Log.scanner.error("Automatic scan skipped Event \(event.id, privacy: .public): AppError")
                } catch {
                    environment.analytics.log(.scanFailed(source: .automatic, reason: .unexpected))
                    FirebaseObservability.recordNonFatal(code: "automatic_scan_unexpected_error")
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
