import SwiftUI

@MainActor
final class CreateEventModel: ObservableObject {
    @Published var name = ""
    @Published var category: EventCategory = .other
    @Published var startsAt = Date()
    @Published var endsAt = Calendar.current.date(byAdding: .day, value: 3, to: Date()) ?? Date().addingTimeInterval(3 * 86_400)
    @Published var locationName = ""
    @Published var isSaving = false
    @Published var errorMessage: String?

    private var env: AppEnvironment?
    private var session: AppSession?

    func configure(env: AppEnvironment, session: AppSession) {
        self.env = env
        self.session = session
    }

    func create() async -> Event? {
        guard let env, let session else { return nil }
        guard let user = session.user, let profile = session.faceProfile else {
            errorMessage = "Complete Face Setup before creating a Trip so SnapLoop can find your photos."
            return nil
        }
        isSaving = true
        defer { isSaving = false }
        do {
            let factory = EventFactory(config: env.config.current, clock: env.clock)
            let draft = EventDraft(
                name: name,
                category: category,
                startsAt: startsAt,
                endsAt: endsAt,
                locationName: locationName.isEmpty ? nil : locationName
            )
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

    private var allowedDates: ClosedRange<Date> {
        EventLifecycle.allowedDateRange(now: env.clock.now())
    }

    private var allowedEndDates: ClosedRange<Date> {
        let durationEnd = EventLifecycle.maximumEndDate(
            from: model.startsAt,
            config: env.config.current
        )
        let upper = min(allowedDates.upperBound, durationEnd)
        return model.startsAt...max(model.startsAt, upper)
    }

    private func suggestedEndDate(from start: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: 3, to: start)
            ?? start.addingTimeInterval(3 * 86_400)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                BrandScreenBackground()
                ScrollView {
                    VStack(spacing: 18) {
                        BrandMark(size: 58)
                        Text("Create a Trip")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.ink)
                        Text("Travel, party, family celebration, wedding — give the shared memories a home.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)

                        PremiumCard {
                            VStack(alignment: .leading, spacing: 14) {
                                fieldLabel("Trip name", icon: "textformat")
                                TextField("e.g. Banff Weekend", text: $model.name)
                                    .textInputAutocapitalization(.words)
                                    .padding(14)
                                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))

                                Divider()
                                fieldLabel("Type", icon: model.category.systemImage)
                                Picker("Type", selection: $model.category) {
                                    ForEach(EventCategory.allCases, id: \.self) { category in
                                        Label(category.displayName, systemImage: category.systemImage).tag(category)
                                    }
                                }
                                .pickerStyle(.menu)
                                .tint(Theme.sunset)

                                Divider()
                                fieldLabel("Location", icon: "location.fill")
                                TextField("Optional", text: $model.locationName)
                                    .textInputAutocapitalization(.words)
                                    .padding(14)
                                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                            }
                        }

                        PremiumCard {
                            VStack(alignment: .leading, spacing: 14) {
                                fieldLabel("Trip dates", icon: "calendar")
                                DatePicker("Starts", selection: $model.startsAt, in: allowedDates, displayedComponents: [.date])
                                    .onChange(of: model.startsAt) { _, newStart in
                                        if model.endsAt < newStart || !allowedEndDates.contains(model.endsAt) {
                                            model.endsAt = min(allowedEndDates.upperBound, suggestedEndDate(from: newStart))
                                        }
                                    }
                                Divider()
                                DatePicker("Ends", selection: $model.endsAt, in: allowedEndDates, displayedComponents: [.date])
                                Text("SnapLoop only considers photos taken within this Trip's selected date range. For this MVP, dates must stay within 15 days before or after today, and a Trip can span at most 15 calendar days.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if let error = model.errorMessage {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote).foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                        }

                        Button {
                            Task {
                                if let event = await model.create() {
                                    onCreated(event)
                                    dismiss()
                                }
                            }
                        } label: {
                            HStack {
                                if model.isSaving { ProgressView().tint(.white) }
                                else { Image(systemName: "sparkles") }
                                Text("Create Trip")
                            }
                        }
                        .buttonStyle(MyPicsTubePrimaryButtonStyle())
                        .disabled(model.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSaving)
                        .opacity(model.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
                    }
                    .padding(20)
                }
            }
            .navigationTitle("New Trip")
            .navigationBarTitleDisplayMode(.inline)
            .task { model.configure(env: env, session: session) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func fieldLabel(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.ink)
    }
}
