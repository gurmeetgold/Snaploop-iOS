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
        } catch let error as AppError { state = .failed(error.userMessage) }
        catch { state = .failed(AppError.unknown("\(error)").userMessage) }
    }
}

struct SyncView: View {
    let event: Event
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @Environment(\.dismiss) private var dismiss
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

                Button { Task { await model.run(event: event) } } label: {
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
                Text("You can keep MyPicsTube open while this finishes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func failed(_ message: String) -> some View {
        PremiumCard {
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 42)).foregroundStyle(Theme.sunset)
                Text("We hit a snag").font(.title3.bold())
                Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Done") { dismiss() }
                    .buttonStyle(MyPicsTubePrimaryButtonStyle())
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
                    Button { Task { await model.run(event: event) } } label: {
                        Label("Scan More", systemImage: "arrow.triangle.2.circlepath")
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
