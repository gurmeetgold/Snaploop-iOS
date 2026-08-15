import SwiftUI

@MainActor
final class HomeModel: ObservableObject {
    @Published var events: [Event] = []
    @Published var isLoading = false

    private var env: AppEnvironment?
    private var session: AppSession?
    func configure(env: AppEnvironment, session: AppSession) { self.env = env; self.session = session }

    func reload() async {
        guard let env, let userId = session?.user?.id else { return }
        isLoading = true; defer { isLoading = false }
        events = (try? await env.events.events(forUserId: userId)) ?? []
    }
}

/// Home: the user's events, with the two entry points to the core loop —
/// create an event or join one.
struct HomeView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @StateObject private var model = HomeModel()
    @State private var showCreate = false
    @State private var showJoin = false
    @State private var joinRoute: DeepLinkRoute?

    var body: some View {
        NavigationStack {
            Group {
                if model.events.isEmpty {
                    emptyState
                } else {
                    eventList
                }
            }
            .navigationTitle("SnapLoop")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { showCreate = true } label: { Label("Create Event", systemImage: "plus") }
                        Button { showJoin = true } label: { Label("Join with Code", systemImage: "qrcode.viewfinder") }
                    } label: { Image(systemName: "plus.circle.fill") }
                }
            }
            .task {
                model.configure(env: env, session: session)
                await model.reload()
            }
            .refreshable { await model.reload() }
            .sheet(isPresented: $showCreate) {
                CreateEventView { _ in Task { await model.reload() } }
            }
            .sheet(isPresented: $showJoin) {
                EnterCodeView { route in showJoin = false; joinRoute = route }
            }
            .sheet(item: $joinRoute) { route in
                NavigationStack {
                    JoinEventView(route: route) { _ in
                        joinRoute = nil; Task { await model.reload() }
                    }
                }
            }
        }
    }

    private var eventList: some View {
        List(model.events) { event in
            NavigationLink { EventDashboardView(event: event) } label: { eventRow(event) }
        }
        .listStyle(.insetGrouped)
    }

    private func eventRow(_ event: Event) -> some View {
        HStack(spacing: 12) {
            Image(systemName: event.category.systemImage)
                .font(.title3).foregroundStyle(.tint).frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.name).font(.headline)
                Text(DateFormatting.range(event.startsAt, event.endsAt))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 44)).foregroundStyle(.secondary)
            Text("You're not in any events yet.").font(.headline)
            Text("Create an event for your trip or party, or join one with a code.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack {
                Button { showCreate = true } label: {
                    Label("Create", systemImage: "plus.circle.fill")
                }.buttonStyle(.borderedProminent)
                Button { showJoin = true } label: {
                    Label("Join", systemImage: "qrcode.viewfinder")
                }.buttonStyle(.bordered)
            }
        }
        .padding()
    }
}

/// Manual "Enter Code" entry (the secondary in-person join path).
struct EnterCodeView: View {
    let onResolved: (DeepLinkRoute) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Enter event code or link") {
                    TextField("e.g. ABC-234", text: $text)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                }
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            }
            .navigationTitle("Join Event")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") {
                        if let route = DeepLinkRouter.route(forManualEntry: text) {
                            onResolved(route)
                        } else {
                            error = AppError.invalidJoinCode.userMessage
                        }
                    }.disabled(text.isEmpty)
                }
            }
        }
    }
}

#Preview {
    HomeView()
        .environmentObject(AppEnvironment.dev())
        .environmentObject(AppSession.dev())
}
