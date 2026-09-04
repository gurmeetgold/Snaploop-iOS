import Photos
import SwiftUI
import UIKit

extension CameraSyncCoordinator.Summary {
    /// CameraSyncCoordinator currently processes at most 100 assets in one pass,
    /// and Release Remote Config clamps the requested batch to at least 100.
    /// Therefore a pass that finishes with `remaining > 0` but fewer than 100
    /// completed assets necessarily had one or more per-asset failures. Treating
    /// those failed assets as a second batch was the reason the UI could show
    /// "Scan complete" followed by "Scan Next Batch" for a 10-photo scan.
    var hasRetryableFailures: Bool {
        remaining > 0 && scanned < 100
    }

    /// True only when the current 100-photo pass completed and there is genuine
    /// additional batch work. Failed assets are recovery work, not a new batch.
    var hasDeferredBatchWork: Bool {
        remaining > 0 && !hasRetryableFailures
    }
}

@MainActor
final class SyncModel: ObservableObject {
    enum State: Equatable { case idle, running(SyncProgress), done(CameraSyncCoordinator.Summary), failed(String) }
    @Published var state: State = .idle

    private var env: AppEnvironment?
    private var session: AppSession?
    private var syncTask: Task<Void, Never>?
    private var resumeAfterBackground = false
    private var isAppActive = true

    func configure(env: AppEnvironment, session: AppSession) {
        self.env = env
        self.session = session
    }

    deinit { syncTask?.cancel() }

    func start(event: Event) {
        resumeAfterBackground = false
        if case .failed = state {
            env?.analytics.log(.scanRetryStarted(source: .manual))
        }
        env?.analytics.log(.scanStarted(source: .manual))
        begin(event: event)
    }

    private func begin(event: Event) {
        guard syncTask == nil else { return }
        syncTask = Task { [weak self] in await self?.run(event: event) }
    }

    func cancel() {
        resumeAfterBackground = false
        if syncTask != nil {
            env?.analytics.log(.scanInterrupted(reason: .userStopped))
        }
        syncTask?.cancel()
    }

    /// iOS does not guarantee foreground-style execution after the app moves to
    /// the background. Stop the active pass cleanly, but remember that it should
    /// resume when SnapLoop becomes active again. CameraSyncCoordinator persists
    /// completed extraction/cursor state before publication, so the restarted pass
    /// continues pending work instead of starting the Event from zero.
    func appDidEnterBackground() {
        isAppActive = false
        guard syncTask != nil else { return }
        env?.analytics.log(.scanBackgrounded())
        env?.analytics.log(.scanInterrupted(reason: .backgrounded))
        resumeAfterBackground = true
        syncTask?.cancel()
    }

    func appDidBecomeActive(event: Event) {
        isAppActive = true
        guard resumeAfterBackground, syncTask == nil else { return }
        env?.analytics.log(.scanResumeAttempted())
        resumeAfterBackground = false
        begin(event: event)
        if syncTask != nil {
            env?.analytics.log(.scanResumeSucceeded())
        }
    }

    func cancelForSafety(message: String) {
        guard syncTask != nil else { return }
        env?.analytics.log(.scanInterrupted(reason: .memoryPressure))
        FirebaseObservability.recordNonFatal(code: "scan_memory_pressure")
        resumeAfterBackground = false
        syncTask?.cancel()
        state = .failed(message)
    }

    private func run(event: Event) async {
        guard let env, let userId = session?.user?.id else {
            syncTask = nil
            return
        }

        state = .running(SyncProgress(phase: .preparing))
        defer {
            syncTask = nil

            // Foreground activation can race with cancellation unwinding. If the
            // app became active before this Task reached defer, restart here.
            if isAppActive && resumeAfterBackground {
                resumeAfterBackground = false
                begin(event: event)
            }
        }

        do {
            let preferences: MemberPhotoPreferences
            if AppEnvironment.useLiveServices {
                preferences = try await MemberPhotoPreferencesClient.load(eventId: event.id)
            } else {
                preferences = MemberPhotoPreferences(sharingEnabled: true, includeOwnMatches: false, revisionToken: "dev")
            }

            guard preferences.sharingEnabled else {
                env.analytics.log(.scanFailed(source: .manual, reason: .sharingDisabled))
                state = .failed("You have turned off photo sharing for this Event. Turn on ‘Share matched pictures from my phone in this Event’ in Event Members before scanning.")
                return
            }

            let manifest = try await EventFaceProfileClient.manifest(eventId: event.id)
            try Task.checkCancellation()

            let performanceTrace = FirebaseObservability.startPerformanceTrace(
                name: "scan_session",
                enabled: env.config.current.performanceMonitoringEnabled
            )
            defer { performanceTrace.stop() }

            let coordinator = env.makeSyncCoordinator()
            let summary = try await coordinator.sync(
                event: event,
                participants: manifest.participants,
                currentUserId: userId,
                sourceMembershipId: manifest.sourceMembershipId,
                includeOwnMatches: preferences.includeOwnMatches,
                preferenceRevision: preferences.revisionToken
            ) { [weak self] progress in
                Task { @MainActor in self?.state = .running(progress) }
            }

            performanceTrace.setMetric("scanned", value: summary.scanned)
            performanceTrace.setMetric("matched_photos", value: summary.matchedPhotos)
            performanceTrace.setMetric("remaining", value: summary.remaining)

            if summary.hasRetryableFailures {
                env.analytics.log(.scanFailed(source: .manual, reason: .retryableWork))
                FirebaseObservability.recordNonFatal(
                    code: "scan_retryable_work_pending",
                    context: [
                        "scanned": .int(summary.scanned),
                        "remaining": .int(summary.remaining),
                    ]
                )
                let noun = summary.remaining == 1 ? "photo is" : "photos are"
                state = .failed("\(summary.remaining) \(noun) still pending because the scan could not finish processing or sharing them. Nothing failed is marked as complete. Try again.")
            } else {
                env.analytics.log(.scanCompleted(
                    source: .manual,
                    scanned: summary.scanned,
                    matchedPhotos: summary.matchedPhotos,
                    remaining: summary.remaining,
                    alreadyCaughtUp: summary.alreadyCaughtUp
                ))
                if summary.scanned > 0 && summary.matchedPhotos == 0 {
                    env.analytics.log(.zeroMatchScanCompleted(
                        source: .manual,
                        scanned: summary.scanned
                    ))
                }
                state = .done(summary)
            }
        } catch is CancellationError {
            // Background cancellation is an implementation detail, not a user-
            // visible scan failure. The pass will resume from its checkpoint on
            // the first foreground opportunity.
            if resumeAfterBackground { return }
            if case .failed = state { return }
            state = .failed(AppError.syncCancelled.userMessage)
        } catch let error as AppError {
            // CameraSyncCoordinator persists its checkpoint and currently maps a
            // cancellation to AppError.syncCancelled. Treat that exactly like the
            // raw CancellationError above when the cancellation came from iOS
            // backgrounding; a user-initiated Stop still surfaces the normal state.
            if error == .syncCancelled && resumeAfterBackground { return }
            if case .failed = state { return }
            env.analytics.log(.scanFailed(source: .manual, reason: .appError))
            FirebaseObservability.recordNonFatal(code: "manual_scan_app_error")
            state = .failed(error.userMessage)
        } catch {
            if case .failed = state { return }
            env.analytics.log(.scanFailed(source: .manual, reason: .unexpected))
            FirebaseObservability.recordNonFatal(code: "manual_scan_unexpected_error")
            let description = (error as NSError).localizedDescription
            if description.localizedCaseInsensitiveContains("not found") {
                state = .failed("Scan service is not deployed yet. Update Firebase Functions and try again.")
            } else {
                state = .failed(description)
            }
        }
    }
}

struct SyncView: View {
    let event: Event
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = SyncModel()
    @State private var photoAccessStatus: PhotoAuthorization = .notDetermined

    var body: some View {
        ZStack {
            BrandScreenBackground()
            VStack(spacing: 20) {
                switch model.state {
                case .idle: idle
                case .running(let progress): running(progress)
                case .done(let summary): done(summary)
                case .failed(let message): failed(message)
                }
            }
            .padding(22)
        }
        .navigationTitle("Scan Photos")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            model.configure(env: env, session: session)
            refreshPhotoAccessStatus()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                model.appDidEnterBackground()
            } else if newPhase == .active {
                refreshPhotoAccessStatus()
                model.appDidBecomeActive(event: event)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            model.cancelForSafety(message: "Photo scan stopped to reduce memory pressure on your iPhone. You can continue later.")
        }
    }

    private var idle: some View {
        PremiumCard {
            VStack(spacing: 16) {
                ZStack {
                    Circle().fill(Theme.brandGradient)
                    Image(systemName: "photo.stack.fill")
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 92, height: 92)
                .shadow(color: Theme.hotPink.opacity(0.22), radius: 14, y: 6)

                Text("Scan Event Photos")
                    .font(.title3.bold())
                    .foregroundStyle(Theme.ink)

                photoAccessNotice

                Button {
                    Task { await beginScanWithPhotoAccessCheck() }
                } label: {
                    Label("Start Scan", systemImage: "sparkles")
                }
                .buttonStyle(MyPicsTubePrimaryButtonStyle())
                .disabled(photoAccessStatus == .denied)
            }
        }
    }

    @ViewBuilder
    private var photoAccessNotice: some View {
        switch photoAccessStatus {
        case .limited:
            VStack(spacing: 8) {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(Color(red: 1.0, green: 0.9, blue: 0.0))
                    Text("Limited Access — Only selected photos can be scanned. Select all event photos from your iPhone or allow full photos access.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }

                Button("Select More Photos") { presentLimitedLibraryPicker() }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.violet)

                Button("Allow Full Photos Access") { openAppSettings() }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.violet)
            }
        case .denied:
            VStack(spacing: 8) {
                Text("Photo access is off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Allow Photo Access") { openAppSettings() }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.violet)
            }
        case .authorized, .notDetermined:
            EmptyView()
        }
    }

    private func running(_ progress: SyncProgress) -> some View {
        PremiumCard {
            VStack(spacing: 18) {
                ZStack {
                    Circle().fill(Theme.brandGradient)
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                }
                .frame(width: 92, height: 92)
                .shadow(color: Theme.hotPink.opacity(0.22), radius: 14, y: 6)

                Text(progress.statusText)
                    .font(.headline).foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)

                Text("Keep SnapLoop open in the foreground until the scan finishes.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button(role: .cancel) { model.cancel() } label: {
                    Label("Stop Scan", systemImage: "stop.circle")
                        .font(.headline)
                        .padding(.horizontal, 22)
                        .frame(height: 46)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.hotPink)
                .background(Theme.hotPink.opacity(0.10), in: Capsule())
            }
        }
    }

    private func failed(_ message: String) -> some View {
        PremiumCard {
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 42)).foregroundStyle(Theme.hotPink)
                Text("Scan stopped").font(.title3.bold())
                Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)

                Button {
                    Task { await beginScanWithPhotoAccessCheck() }
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(MyPicsTubePrimaryButtonStyle())

                Button("Done") { dismiss() }.foregroundStyle(Theme.hotPink)
            }
        }
    }

    @ViewBuilder private func done(_ summary: CameraSyncCoordinator.Summary) -> some View {
        PremiumCard {
            VStack(spacing: 18) {
                ZStack {
                    Circle().fill(Theme.brandGradient)
                    Image(systemName: "checkmark")
                        .font(.system(size: 38, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 94, height: 94)
                .shadow(color: Theme.hotPink.opacity(0.20), radius: 14, y: 6)

                let didCheckPhotos = summary.scanned > 0
                Text(didCheckPhotos ? "Scan complete" : "You're up to date")
                    .font(.title3.bold())
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)

                Text(didCheckPhotos
                     ? "Matched photos are now available to the Event members found in them."
                     : "No new photos need scanning for this Event.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if summary.hasDeferredBatchWork {
                    Button { model.start(event: event) } label: {
                        Label("Scan Next Batch", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(MyPicsTubePrimaryButtonStyle())
                    Button("Done") { dismiss() }.foregroundStyle(Theme.hotPink)
                } else {
                    Button { dismiss() } label: {
                        Label("Done", systemImage: "checkmark.circle.fill")
                    }
                    .buttonStyle(MyPicsTubePrimaryButtonStyle())
                }
            }
        }
    }

    @MainActor
    private func beginScanWithPhotoAccessCheck() async {
        var status = env.photoLibrary.authorizationStatus()
        if status == .notDetermined {
            status = await env.photoLibrary.requestAuthorization()
        }
        photoAccessStatus = status

        switch status {
        case .authorized, .limited:
            model.start(event: event)
        case .denied, .notDetermined:
            return
        }
    }

    @MainActor
    private func refreshPhotoAccessStatus() {
        photoAccessStatus = env.photoLibrary.authorizationStatus()
    }

    @MainActor
    private func presentLimitedLibraryPicker() {
        guard photoAccessStatus == .limited,
              let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              let rootViewController = scene.windows.first(where: \.isKeyWindow)?.rootViewController else {
            return
        }

        var presenter = rootViewController
        while let presented = presenter.presentedViewController {
            presenter = presented
        }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: presenter)
    }

    @MainActor
    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
