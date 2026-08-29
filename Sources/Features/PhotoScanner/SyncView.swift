import Photos
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
                state = .failed("You have turned off photo sharing for this Event. Turn on ‘Share matched pictures from my phone in this Event’ in Event Members before scanning.")
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
    @State private var showLimitedAccessOptions = false
    @State private var showPhotoAccessDenied = false

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
        .navigationTitle("Scan Event Photos")
        .navigationBarTitleDisplayMode(.inline)
        .task { model.configure(env: env, session: session) }
        .onDisappear { model.cancel() }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                model.cancelForSafety(message: "Photo scan stopped because SnapLoop moved to the background. Return to SnapLoop and try again.")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            model.cancelForSafety(message: "Photo scan stopped to reduce memory pressure on your iPhone. You can continue later.")
        }
        .confirmationDialog(
            "Selected Photos Access",
            isPresented: $showLimitedAccessOptions,
            titleVisibility: .visible
        ) {
            Button("Select More Event Photos") { presentLimitedPhotoPicker() }
            Button("Allow Full Photo Access") { openAppSettings() }
            Button("Continue With Selected Photos") { model.start(event: event) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("SnapLoop can currently see only the photos you selected. To avoid missing matches, select all photos from this Event’s dates or allow Full Photo Access. SnapLoop scans only photos taken during this Event’s date range.")
        }
        .alert("Photos Access Needed", isPresented: $showPhotoAccessDenied) {
            Button("Open Settings") { openAppSettings() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Allow SnapLoop to access photos so it can check this Event’s date range for matches. SnapLoop does not scan photos outside the Event dates.")
        }
    }

    private var idle: some View {
        PremiumCard {
            VStack(spacing: 18) {
                ZStack {
                    Circle().fill(Theme.brandGradient)
                    Image(systemName: "photo.stack.fill")
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 92, height: 92)
                .shadow(color: Theme.hotPink.opacity(0.22), radius: 14, y: 6)

                Text("Scan this iPhone for Event photos")
                    .font(.title3.bold()).foregroundStyle(Theme.ink)
                Text("SnapLoop checks only photos taken during this Event’s date range and matches Event members on-device.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button {
                    Task { await beginScanWithPhotoAccessCheck() }
                } label: {
                    Label("Start Scan", systemImage: "sparkles")
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

                Text("Keep SnapLoop open while it checks this iPhone for Event photos.")
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

                Text(summary.alreadyCaughtUp ? "You're up to date" : "Scan complete")
                    .font(.title3.bold())
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)

                Text(summary.alreadyCaughtUp
                     ? "No new photos need scanning for this Event."
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

    @MainActor
    private func beginScanWithPhotoAccessCheck() async {
        var status = env.photoLibrary.authorizationStatus()
        if status == .notDetermined {
            status = await env.photoLibrary.requestAuthorization()
        }

        switch status {
        case .authorized:
            model.start(event: event)
        case .limited:
            showLimitedAccessOptions = true
        case .denied, .notDetermined:
            showPhotoAccessDenied = true
        }
    }

    @MainActor
    private func presentLimitedPhotoPicker() {
        guard let controller = Self.topViewController() else {
            openAppSettings()
            return
        }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: controller)
    }

    @MainActor
    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    @MainActor
    private static func topViewController() -> UIViewController? {
        let root = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: { $0.isKeyWindow })?
            .rootViewController

        var current = root
        while let presented = current?.presentedViewController { current = presented }
        if let navigation = current as? UINavigationController { return navigation.visibleViewController ?? navigation }
        if let tab = current as? UITabBarController { return tab.selectedViewController ?? tab }
        return current
    }
}
