import SwiftUI

@MainActor
final class EditEventModel: ObservableObject {
    @Published var name: String
    @Published var category: EventCategory
    @Published var startsAt: Date
    @Published var endsAt: Date
    @Published var locationName: String
    @Published var isSaving = false
    @Published var errorMessage: String?

    private var baseline: Event
    private var env: AppEnvironment?
    private var didConfigure = false

    init(event: Event) {
        baseline = event
        name = event.name
        category = event.category
        startsAt = event.startsAt
        endsAt = event.endsAt
        locationName = event.locationName ?? ""
    }

    func configure(env: AppEnvironment) async {
        guard !didConfigure else { return }
        didConfigure = true
        self.env = env

        if AppEnvironment.useLiveServices {
            do {
                let fresh = try await env.events.fetchEvent(id: baseline.id)
                baseline = fresh
                name = fresh.name
                category = fresh.category
                startsAt = fresh.startsAt
                endsAt = fresh.endsAt
                locationName = fresh.locationName ?? ""
            } catch {
                errorMessage = EventManagementClient.userMessage(for: error)
                return
            }
        }

        let allowed = EventLifecycle.allowedDateRange(now: env.clock.now())
        var adjusted = false

        if startsAt < allowed.lowerBound {
            startsAt = allowed.lowerBound
            adjusted = true
        } else if startsAt > allowed.upperBound {
            startsAt = Calendar.current.date(byAdding: .day, value: -1, to: allowed.upperBound)
                ?? allowed.upperBound.addingTimeInterval(-86_400)
            adjusted = true
        }

        let maximumEnd = min(
            allowed.upperBound,
            EventLifecycle.maximumEndDate(from: startsAt, config: env.config.current)
        )
        if endsAt <= startsAt || endsAt > maximumEnd || !allowed.contains(endsAt) {
            let suggested = Calendar.current.date(byAdding: .day, value: 3, to: startsAt)
                ?? startsAt.addingTimeInterval(3 * 86_400)
            endsAt = min(maximumEnd, suggested)
            adjusted = true
        }

        if adjusted {
            errorMessage = "This older event uses dates outside the current limits. Review the adjusted dates before saving."
        } else {
            errorMessage = nil
        }
    }

    func save() async -> Event? {
        guard let env else { return nil }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            let draft = EventDraft(
                name: name,
                category: category,
                startsAt: startsAt,
                endsAt: endsAt,
                locationName: locationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : locationName.trimmingCharacters(in: .whitespacesAndNewlines),
                coverImagePath: baseline.coverImagePath
            )
            let updated = try EventFactory(config: env.config.current, clock: env.clock).applyEdit(draft, to: baseline)

            if updated.name == baseline.name,
               updated.category == baseline.category,
               updated.locationName == baseline.locationName,
               updated.startsAt == baseline.startsAt,
               updated.endsAt == baseline.endsAt {
                errorMessage = "No changes to save."
                return nil
            }

            if AppEnvironment.useLiveServices {
                _ = try await EventManagementClient.update(updated, expectedUpdatedAt: baseline.updatedAt)
            } else {
                try await env.events.updateEventDetails(
                    id: updated.id,
                    name: updated.name,
                    category: updated.category,
                    coverImagePath: updated.coverImagePath,
                    locationName: updated.locationName
                )
                try await env.events.updateEventDates(id: updated.id, startsAt: updated.startsAt, endsAt: updated.endsAt)
            }
            return updated
        } catch {
            errorMessage = EventManagementClient.userMessage(for: error)
        }
        return nil
    }
}

struct EditEventView: View {
    let event: Event
    let onSaved: (Event) -> Void

    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: EditEventModel

    init(event: Event, onSaved: @escaping (Event) -> Void) {
        self.event = event
        self.onSaved = onSaved
        _model = StateObject(wrappedValue: EditEventModel(event: event))
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
        ZStack {
            BrandScreenBackground()
            ScrollView {
                VStack(spacing: 18) {
                    BrandMark(size: 54)
                    Text("Edit Event")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.ink)

                    PremiumCard {
                        VStack(alignment: .leading, spacing: 14) {
                            Label("Event name", systemImage: "textformat").font(.subheadline.bold())
                            TextField("Event name", text: $model.name)
                                .textInputAutocapitalization(.words)
                                .padding(14)
                                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                            Divider()
                            Label("Type", systemImage: model.category.systemImage).font(.subheadline.bold())
                            Picker("Type", selection: $model.category) {
                                ForEach(EventCategory.allCases, id: \.self) { category in
                                    Label(category.displayName, systemImage: category.systemImage).tag(category)
                                }
                            }
                            .pickerStyle(.menu)
                            .tint(Theme.sunset)
                            Divider()
                            Label("Location", systemImage: "location.fill").font(.subheadline.bold())
                            TextField("Optional", text: $model.locationName)
                                .textInputAutocapitalization(.words)
                                .padding(14)
                                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                        }
                    }

                    PremiumCard {
                        VStack(alignment: .leading, spacing: 14) {
                            Label("Event dates", systemImage: "calendar").font(.subheadline.bold())
                            Text("Organizer and Admins can change dates. Other members are notified; they do not need to approve the change.")
                                .font(.caption).foregroundStyle(.secondary)
                            DatePicker("Starts", selection: $model.startsAt, in: allowedDates, displayedComponents: [.date])
                                .onChange(of: model.startsAt) { _, newStart in
                                    if model.endsAt < newStart || !allowedEndDates.contains(model.endsAt) {
                                        model.endsAt = min(allowedEndDates.upperBound, suggestedEndDate(from: newStart))
                                    }
                                }
                            Divider()
                            DatePicker("Ends", selection: $model.endsAt, in: allowedEndDates, displayedComponents: [.date])
                            Text("Dates must stay within 15 days before or after today, and the event can span at most 15 calendar days.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    if let error = model.errorMessage {
                        Label(error, systemImage: "info.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    Button {
                        Task {
                            if let updated = await model.save() {
                                onSaved(updated)
                                dismiss()
                            }
                        }
                    } label: {
                        HStack {
                            if model.isSaving { ProgressView().tint(.white) }
                            else { Image(systemName: "checkmark.circle.fill") }
                            Text("Save Event")
                        }
                    }
                    .buttonStyle(MyPicsTubePrimaryButtonStyle())
                    .disabled(model.isSaving || model.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(20)
            }
        }
        .navigationTitle("Edit Event")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.configure(env: env) }
    }
}
