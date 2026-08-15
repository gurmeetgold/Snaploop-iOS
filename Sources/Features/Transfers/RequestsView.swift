import SwiftUI

@MainActor
final class RequestsModel: ObservableObject {
    @Published var waitingOnOthers: [TransferJob] = []   // I'm the requester
    @Published var othersWaitingOnMe: [TransferJob] = [] // I'm the source
    private var env: AppEnvironment?
    private var session: AppSession?
    let event: Event
    init(event: Event) { self.event = event }
    func configure(env: AppEnvironment, session: AppSession) { self.env = env; self.session = session }

    func reload() async {
        guard let env, let userId = session?.user?.id else { return }
        let all = (try? await env.transfers.transfers(involvingUserId: userId)) ?? []
        let scoped = all.filter { $0.eventId == event.id }
        waitingOnOthers = scoped.filter { $0.requestingUserId == userId }
        othersWaitingOnMe = scoped.filter { $0.sourceUserId == userId }
    }
}

/// Requests & Transfers, scoped to one trip. Visually modeled on the product's
/// Requests screen, but functionally honest to the architecture we built: an
/// original moves via a server-issued signed URL with a TTL — never a direct
/// device-to-device (Bluetooth/Wi-Fi) pairing — so state here is read-only,
/// driven by the trusted Cloud Function state machine (`TransferJob`).
struct RequestsView: View {
    let event: Event
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @StateObject private var model: RequestsModel
    init(event: Event) {
        self.event = event
        _model = StateObject(wrappedValue: RequestsModel(event: event))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Requests & Transfers")
                    .font(.title3).bold().foregroundStyle(Theme.ink)
                    .padding(.horizontal)
                Text("Send, receive, and keep your trip memories flowing.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .padding(.horizontal)

                section("Waiting on others", jobs: model.waitingOnOthers, iAmRequester: true)
                section("Others waiting on you", jobs: model.othersWaitingOnMe, iAmRequester: false)

                Label("Originals are shared through a secure, temporary link that expires after a few days — never sent directly between phones.",
                      systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Requests")
        .navigationBarTitleDisplayMode(.inline)
        .task { model.configure(env: env, session: session); await model.reload() }
        .refreshable { await model.reload() }
    }

    private func section(_ title: String, jobs: [TransferJob], iAmRequester: Bool) -> some View {
        Group {
            if !jobs.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(title).font(.headline).padding(.horizontal)
                    VStack(spacing: 10) {
                        ForEach(jobs) { job in RequestRow(job: job, iAmRequester: iAmRequester) }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }
}

private struct RequestRow: View {
    let job: TransferJob
    let iAmRequester: Bool

    /// `TransferJob.userStatus` is written from the requester's point of view;
    /// flip the copy when the current user is the source so it never reads as
    /// "waiting for the original from yourself".
    private var statusText: String {
        if iAmRequester { return job.userStatus(sourceName: job.sourceUserId) }
        switch job.status {
        case .queued, .sourceNotified:
            return "\(job.requestingUserId) wants a photo from your phone."
        case .uploading:
            return "Sending to \(job.requestingUserId)…"
        case .ready, .downloading:
            return "Ready for \(job.requestingUserId) to download."
        case .completed:
            return "Sent."
        case .failed:
            return "Something went wrong. We'll try again."
        case .expired:
            return "This request expired."
        }
    }

    private var tint: Color {
        switch job.status {
        case .completed: return .green
        case .failed, .expired: return .red
        case .ready: return Theme.sky
        default: return Theme.amber
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Theme.violetGradient)
                Image(systemName: iAmRequester ? "arrow.down" : "arrow.up")
                    .font(.caption).foregroundStyle(.white)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(iAmRequester ? "From \(job.sourceUserId)" : "For \(job.requestingUserId)")
                    .font(.subheadline).bold()
                Text(statusText)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            StatusPill(text: job.status.rawValue.replacingOccurrences(of: "_", with: " ").capitalized, tint: tint)
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.separator.opacity(0.4)))
    }
}
