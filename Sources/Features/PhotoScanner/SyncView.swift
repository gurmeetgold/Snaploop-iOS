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

struct SyncView: View {
    let event: Event
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @Environment(\.dismiss) private var dismiss
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
                VStack(spacing: 18) {
                    ContentUnavailableViewCompat(title: "We hit a snag", message: message)
                    Button("Done") { dismiss() }
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding()
        .navigationTitle("Sync My Camera")
        .navigationBarTitleDisplayMode(.inline)
        .task { model.configure(env: env, session: session) }
    }

    private var idle: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 44)).foregroundStyle(.tint)
            Text("We'll look through your photos from this event and find confident matches on-device.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("Start") { Task { await model.run(event: event) } }
                .buttonStyle(.borderedProminent).controlSize(.large)
        }
    }

    private func running(_ progress: SyncProgress) -> some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text(progress.statusText).font(.headline).multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private func done(_ summary: CameraSyncCoordinator.Summary) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 54)).foregroundStyle(.green)
            Text(summary.alreadyCaughtUp
                 ? "You're all caught up."
                 : "Found \(summary.matchedPhotos) \(summary.matchedPhotos == 1 ? "photo" : "photos") of you.")
                .font(.headline)
                .multilineTextAlignment(.center)

            if summary.hasMore {
                Button("Scan More") { Task { await model.run(event: event) } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                Button("Done") { dismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            } else {
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
    }
}
