import SwiftUI
import UIKit

@MainActor
final class SyncModel: ObservableObject {
    enum State: Equatable { case idle, running(SyncProgress), done(CameraSyncCoordinator.Summary), failed(String) }
    @Published var state: State = .idle

    private var env: AppEnvironment?
    private var session: AppSession?
    private var syncTask: Task<Void, Never>?

    func configure(env: AppEnvironment, session: AppSession) {
        self.env = env
        self.session = session
    }

    deinit { syncTask?.cancel() }

    func start(event: Event) {
        guard syncTask == nil else { return }
        syncTask = Task { [weak self] in await self?.run(event: event) }
    }

    func cancel() { syncTask?.cancel() }

    func cancelForSafety(message: String) {
        guard syncTask != nil else { return }
        syncTask?.cancel()
        state = .failed(message)
    }

    private func run(event: Event) async {
        guard let env, let userId = session?.user?.id else {
            syncTask = nil
            return
        }

        state = .running(SyncProgress(phase: .preparing))
        defer { syncTask = nil }

        do {
            let preferences: MemberPhotoPreferences
            if AppEnvironment.useLiveServices {
                preferences = try await MemberPhotoPreferencesClient.load(eventId: event.id)
            } else {
                preferences = MemberPhotoPreferences(sharingEnabled: true, includeOwnMatches: false, revisionToken: "dev")
            }

            guard preferences.sharingEnabled else {
                state = .failed("You have turned off photo sharing for this Event. Turn on ‘Share matched pictures from my phone in this Event’ in Event Members before syncing.")
                return
            }

            let participants = try await EventFaceProfileClient.list(eventId: event.id)
            try Task.checkCancellation()
            let coordinator = env.makeSyncCoordinator()
            let summary = try await coordinator.sync(
                event: event,
                participants: participants,
                currentUserId: userId,
                includeOwnMatches: preferences.includeOwnMatches,
                preferenceRevision: preferences.revisionToken
            ) { [weak self] progress in
                Task { @MainActor in self?.state = .running(progress) }
            }
            state = .done(summary)
        } catch is CancellationError {
            if case .failed = state { return }
            state = .failed(AppError.syncCancelled.userMessage)
        } catch let error as AppError {
            if case .failed = state { return }
            state = .failed(error.userMessage)
        } catch {
            if case .failed = state { return }
            let description = (error as NSError).localizedDescription
            if description.localizedCaseInsensitiveContains("not found") {
                state = .failed("Sync service is not deployed yet. Update Firebase Functions and try again.")
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
        .navigationTitle("Sync My Camera")
        .navigationBarTitleDisplayMode(.inline)
        .task { model.configure(env: env, session: session) }
        .onDisappear { model.cancel() }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                model.cancelForSafety(message: "Camera sync stopped because SnapLoop moved to the background. Return to SnapLoop and try again.")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            model.cancelForSafety(message: "Camera sync stopped to reduce memory pressure on your iPhone. You can continue later.")
        }
    }

    private var idle: some View {
        PremiumCard {
            VStack(spacing: 18) {
                ZStack {
                    Circle().fill(Theme.brandGradient)
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 92, height: 92)
                .shadow(color: Theme.hotPink.opacity(0.22), radius: 14, y: 6)

                Text("Find photos from this Event")
                    .font(.title3.bold()).foregroundStyle(Theme.ink)
                Text("SnapLoop checks this Event's selected date window on your iPhone and matches Event members on-device.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button { model.start(event: event) } label: {
                    Label("Start Sync", systemImage: "sparkles")
                }
                .buttonStyle(MyPicsTubePrimaryButtonStyle())
            }
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

                Text("Keep SnapLoop open to scan for latest photos of the Event.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button(role: .cancel) { model.cancel() } label: {
                    Label("Stop Sync", systemImage: "stop.circle")
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
                Text("Sync stopped").font(.title3.bold())
                Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)

                Button { model.start(event: event) } label: {
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

                Text("Scan complete")
                    .font(.title3.bold())
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)

                Text(summary.alreadyCaughtUp
                     ? "You're up to date for this Event."
                     : "Matched photos are now available to the Event members found in them.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if summary.hasMore {
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
}
