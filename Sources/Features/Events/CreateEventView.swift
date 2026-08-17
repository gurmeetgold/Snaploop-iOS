import SwiftUI

@MainActor
final class CreateEventModel: ObservableObject {
    @Published var name = ""
    @Published var category: EventCategory = .other
    @Published var startsAt = Date()
    @Published var endsAt = Date().addingTimeInterval(3 * 86_400)
    @Published var locationName = ""
    @Published var isSaving = false
    @Published var errorMessage: String?

    private var env: AppEnvironment?
    private var session: AppSession?
    init() {}
    func configure(env: AppEnvironment, session: AppSession) {
        self.env = env; self.session = session
    }

    func create() async -> Event? {
        guard let env, let session else { return nil }
        guard let user = session.user, let profile = session.faceProfile else {
            errorMessage = AppError.notAuthenticated.userMessage; return nil
        }
        isSaving = true; defer { isSaving = false }
        do {
            let factory = EventFactory(config: env.config.current, clock: env.clock)
            let draft = EventDraft(
                name: name, category: category,
                startsAt: startsAt, endsAt: endsAt,
                locationName: locationName.isEmpty ? nil : locationName)
            let event = try factory.make(draft: draft, creatorUserId: user.id)
            let membership = EventMembershipService(repository: env.events, config: env.config, clock: env.clock)
            try await membership.create(event: event, creator: user, faceProfile: profile)
            return event
        } catch let error as AppError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = AppError.unknown("\(error)").userMessage
        }
        return nil
    }
}

struct CreateEventView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: CreateEventModel
    let onCreated: (Event) -> Void

    init(onCreated: @escaping (Event) -> Void) {
        self.onCreated = onCreated
        _model = StateObject(wrappedValue: CreateEventModel())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Event") {
                    TextField("Name (e.g. Family Reunion, Goa Trip)", text: $model.name)
                    Picker("Type", selection: $model.category) {
                        ForEach(EventCategory.allCases, id: \.self) { c in
                            Label(c.displayName, systemImage: c.systemImage).tag(c)
                        }
                    }
                    TextField("Location (optional)", text: $model.locationName)
                }
                Section("Dates") {
                    DatePicker("Starts", selection: $model.startsAt, displayedComponents: [.date])
                    DatePicker("Ends", selection: $model.endsAt, displayedComponents: [.date])
                    if model.startsAt < Date() {
                        Label("We'll also look back through photos from before today.",
                              systemImage: "clock.arrow.circlepath")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let error = model.errorMessage {
                    Section { Text(error).foregroundStyle(.red).font(.footnote) }
                }
            }
            .navigationTitle("New Event")
            .task { model.configure(env: env, session: session) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task {
                            if let event = await model.create() { onCreated(event); dismiss() }
                        }
                    }
                    .disabled(model.name.trimmingCharacters(in: .whitespaces).isEmpty || model.isSaving)
                }
            }
        }
    }
}
