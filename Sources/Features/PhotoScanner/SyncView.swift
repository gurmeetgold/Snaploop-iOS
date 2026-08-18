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

    deinit {
        syncTask?.cancel()
    }

    func start(event: Event) {
        guard syncTask == nil else { return }
        syncTask = Task { [weak self] in
            await self?.run(event: event)
        }
    }

    func cancel() {
        syncTask?.cancel()
    }

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
            let participants = try await env.events.participants(eventId: event.id)
            try Task.checkCancellation()

            let coordinator = env.makeSyncCoordinator()
            let summary = try await coordinator.sync(
                event: event,
                participants: participants,
                currentUserId: userId
            ) { [weak self] progress in
                Task { @MainActor in
                    self?.state = .running(progress)
                }
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
            state = .failed(AppError.unknown("\(error)").userMessage)
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
            if newPhase != .active {
                model.cancelForSafety(message: "Camera sync stopped because MyPicsTube left the foreground. You can continue when you return.")
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
                    Circle().fill(Theme.aqua.opacity(0.14))
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(Theme.aqua)
                }
                .frame(width: 92, height: 92)

                Text("Find your event photos")
                    .font(.title3.bold()).foregroundStyle(Theme.ink)
                Text("MyPicsTube scans photos from this event's date window on this iPhone and looks for confident matches on-device.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Text("For beta safety, each pass processes a small batch. You can stop at any time and continue later.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    Circle().fill(Theme.sunset.opacity(0.13))
                    ProgressView().controlSize(.large).tint(Theme.sunset)
                }
                .frame(width: 88, height: 88)

                Text(progress.statusText)
                    .font(.headline).foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)

                Text("Keep MyPicsTube in the foreground while scanning. The scan pauses automatically for heat, memory pressure, or when you leave the app.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button(role: .cancel) {
                    model.cancel()
                } label: {
                    Label("Stop Sync", systemImage: "stop.circle")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func failed(_ message: String) -> some View {
        PremiumCard {
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 42)).foregroundStyle(Theme.sunset)
                Text("Sync stopped").font(.title3.bold())
                Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)

                Button { model.start(event: event) } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(MyPicsTubePrimaryButtonStyle())

                Button("Done") { dismiss() }
                    .foregroundStyle(Theme.sunset)
            }
        }
    }

    @ViewBuilder
    private func done(_ summary: CameraSyncCoordinator.Summary) -> some View {
        PremiumCard {
            VStack(spacing: 18) {
                ZStack {
                    Circle().fill(Color.green.opacity(0.12))
                    Image(systemName: summary.alreadyCaughtUp ? "checkmark.circle.fill" : "sparkles")
                        .font(.system(size: 46)).foregroundStyle(summary.alreadyCaughtUp ? .green : Theme.sunset)
                }
                .frame(width: 94, height: 94)

                Text(summary.alreadyCaughtUp
                     ? "You're all caught up"
                     : "Found \(summary.matchedPhotos) \(summary.matchedPhotos == 1 ? "photo" : "photos") of you")
                    .font(.title3.bold()).foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)

                Text(summary.alreadyCaughtUp
                     ? "No new photos needed processing for this event."
                     : "Your confident matches are ready in My Photos.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)

                if summary.hasMore {
                    Button { model.start(event: event) } label: {
                        Label("Scan Next Batch", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(MyPicsTubePrimaryButtonStyle())

                    Button("Done") { dismiss() }
                        .foregroundStyle(Theme.sunset)
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
