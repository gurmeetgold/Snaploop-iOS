import SwiftUI

@MainActor
final class EditEventModel: ObservableObject {
    static let maximumNameCharacters = 20

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

    var editingCalendar: Calendar { baseline.photoWindowCalendar }
    var editingTimeZone: TimeZone { editingCalendar.timeZone }

    func enforceNameCharacterLimit() {
        if name.count > Self.maximumNameCharacters {
            name = String(name.prefix(Self.maximumNameCharacters))
        }
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

        // Never clamp an Event merely by opening Edit. Historical/legacy Events
        // may legitimately sit outside today's creation window. Their dates stay
        // byte-for-byte unchanged unless the user deliberately edits a date.
        errorMessage = nil
    }

    func save() async -> Event? {
        guard let env else { return nil }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            let trimmedLocation = locationName.trimmingCharacters(in: .whitespacesAndNewlines)
            let draft = EventDraft(
                name: name,
                category: category,
                startsAt: startsAt,
                endsAt: endsAt,
                locationName: trimmedLocation.isEmpty ? nil : trimmedLocation,
                coverImagePath: baseline.coverImagePath
            )
            let datesChanged = dateSelectionChanged()
            let updated = try EventFactory(
                config: env.config.current,
                clock: env.clock,
                calendar: editingCalendar
            ).applyEdit(draft, to: baseline, datesChanged: datesChanged)

            if updated.name == baseline.name,
               updated.category == baseline.category,
               updated.locationName == baseline.locationName,
               !datesChanged {
                errorMessage = "No changes to save."
                return nil
            }

            if AppEnvironment.useLiveServices {
                _ = try await EventManagementClient.update(
                    updated,
                    expectedUpdatedAt: baseline.updatedAt,
                    includeDates: datesChanged
                )
            } else {
                try await env.events.updateEventDetails(
                    id: updated.id,
                    name: updated.name,
                    category: updated.category,
                    coverImagePath: updated.coverImagePath,
                    locationName: updated.locationName
                )
                if datesChanged {
                    try await env.events.updateEventDates(
                        id: updated.id,
                        startsAt: updated.startsAt,
                        endsAt: updated.endsAt
                    )
                }
            }
            return updated
        } catch {
            errorMessage = EventManagementClient.userMessage(for: error)
        }
        return nil
    }

    private func dateSelectionChanged() -> Bool {
        let calendar = editingCalendar
        return !calendar.isDate(startsAt, inSameDayAs: baseline.startsAt)
            || !calendar.isDate(endsAt, inSameDayAs: baseline.endsAt)
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

    private func suggestedEndDate(from start: Date) -> Date {
        model.editingCalendar.date(byAdding: .day, value: 3, to: start)
            ?? start.addingTimeInterval(3 * 86_400)
    }

    private func repairEndAfterStartChange(_ newStart: Date) {
        let calendar = model.editingCalendar
        let startDay = calendar.startOfDay(for: newStart)
        let endDay = calendar.startOfDay(for: model.endsAt)
        let distance = calendar.dateComponents([.day], from: startDay, to: endDay).day ?? -1
        let maxDays = min(EventLifecycle.mvpMaximumDurationDays, max(1, env.config.current.maxEventDurationDays))
        guard distance < 0 || distance > maxDays else { return }

        let maxEnd = EventLifecycle.maximumEndDate(
            from: newStart,
            config: env.config.current,
            calendar: calendar
        )
        model.endsAt = min(maxEnd, suggestedEndDate(from: newStart))
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
                                .onChange(of: model.name) { _, _ in
                                    model.enforceNameCharacterLimit()
                                }
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
                            DatePicker("Starts", selection: $model.startsAt, displayedComponents: [.date])
                                .environment(\.timeZone, model.editingTimeZone)
                                .onChange(of: model.startsAt) { _, newStart in
                                    repairEndAfterStartChange(newStart)
                                }
                            Divider()
                            DatePicker("Ends", selection: $model.endsAt, displayedComponents: [.date])
                                .environment(\.timeZone, model.editingTimeZone)
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