import SwiftUI

@MainActor
final class SyncModel: ObservableObject {
    enum State: Equatable { case idle, running(SyncProgress), done(CameraSyncCoordinator.Summary), failed(String) }
    @Published var state: State = .idle

    private var env: AppEnvironment?
    private var session: AppSession?
    func configure(env: AppEnvironment, session: AppSession) { self.env = env; self.session = session }

    func run(event: Event) async {
        guard let env, let userId = session?.user?.id else { return }
        state = .running(SyncProgress(phase: .preparing))
        do {
            let participants = try await env.events.participants(eventId: event.id)
            let coordinator = env.makeSyncCoordinator()
            let summary = try await coordinator.sync(
                event: event, participants: participants, currentUserId: userId
            ) { [weak self] progress in
                Task { @MainActor in self?.state = .running(progress) }
            }
            state = .done(summary)
        } catch let error as AppError {
            state = .failed(error.userMessage)
        } catch {
            state = .failed(AppError.unknown("\(error)").userMessage)
        }
    }
}

/// "Sync My Camera" — on-demand, with real staged progress (never a blank
/// spinner). Copy stays human throughout.
struct SyncView: View {
    let event: Event
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @StateObject private var model = SyncModel()

    var body: some View {
        VStack(spacing: 20) {
            switch model.state {
            case .idle:
                idle
            case .running(let progress):
                running(progress)
            case .done(let summary):
                done(summary)
            case .failed(let message):
                ContentUnavailableViewCompat(title: "We hit a snag", message: message)
            }
        }
        .padding()
        .navigationTitle("Sync My Camera")
        .navigationBarTitleDisplayMode(.inline)
        .task { model.configure(env: env, session: session) }
    }

    private var idle: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 44)).foregroundStyle(.tint)
            Text("We'll look through your photos from this event and find the ones you're in.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("Start") { Task { await model.run(event: event) } }
                .buttonStyle(.borderedProminent).controlSize(.large)

            if FaceModelPolicy.usesDevelopmentDescriptor {
                Text("Development face matching is enabled for this Xcode build. Use it to validate the complete photo-sharing loop before we install the release identity model.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func running(_ progress: SyncProgress) -> some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text(progress.statusText).font(.headline).multilineTextAlignment(.center)
        }
    }

    private func done(_ summary: CameraSyncCoordinator.Summary) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 48)).foregroundStyle(.green)
            Text(summary.alreadyCaughtUp
                 ? "You're all caught up."
                 : "Found \(summary.matchedPhotos) \(summary.matchedPhotos == 1 ? "photo" : "photos") of you.")
                .font(.headline)
            if summary.hasMore {
                Button("Keep going") { Task { await model.run(event: event) } }
                    .buttonStyle(.bordered)
            }
        }
    }
}
