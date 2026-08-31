import FirebaseFunctions
import Foundation

/// Thin client for trusted event mutations that must be enforced server-side.
/// Existing repository reads remain unchanged.
enum EventManagementClient {
    @MainActor
    static func create(_ event: Event) async throws {
        var data: [String: Any] = [
            "id": event.id,
            "joinCode": event.joinCode,
            "inviteToken": event.inviteToken,
            "creatorUserId": event.creatorUserId,
            "name": event.name,
            "category": event.category.rawValue,
            "coverImagePath": NSNull(),
            "locationName": NSNull(),
            "status": event.status.rawValue,
            "createdAtMillis": millis(event.createdAt),
            "updatedAtMillis": millis(event.updatedAt),
        ]
        datePayload(for: event).forEach { data[$0.key] = $0.value }
        if let cover = event.coverImagePath { data["coverImagePath"] = cover }
        if let location = event.locationName { data["locationName"] = location }
        _ = try await call("createEvent", data: data)
    }

    @MainActor
    static func join(eventId: String) async throws {
        _ = try await call("joinEvent", data: ["eventId": eventId])
    }

    /// Date fields are intentionally omitted for rename/details-only edits. This
    /// prevents an old Event from being normalized or rejected merely because its
    /// historical dates now fall outside today's ±15-day creation/edit window.
    @MainActor
    static func update(
        _ event: Event,
        expectedUpdatedAt: Date? = nil,
        includeDates: Bool = true
    ) async throws -> Bool {
        var data: [String: Any] = [
            "eventId": event.id,
            "name": event.name,
            "category": event.category.rawValue,
            "coverImagePath": NSNull(),
            "locationName": NSNull(),
        ]
        if includeDates {
            datePayload(for: event).forEach { data[$0.key] = $0.value }
        }
        if let expectedUpdatedAt {
            data["expectedUpdatedAtMillis"] = millis(expectedUpdatedAt)
        }
        if let cover = event.coverImagePath { data["coverImagePath"] = cover }
        if let location = event.locationName { data["locationName"] = location }
        let raw = try await call("updateEventManaged", data: data)
        return (raw as? [String: Any])?["changed"] as? Bool ?? true
    }

    @MainActor
    static func setRole(eventId: String, userId: String, role: EventMember.Role) async throws {
        guard role == .admin || role == .participant else { return }
        _ = try await call("manageEventMember", data: [
            "eventId": eventId,
            "userId": userId,
            "action": "setRole",
            "role": role.rawValue,
        ])
    }

    @MainActor
    static func remove(eventId: String, userId: String) async throws {
        _ = try await call("leaveEvent", data: [
            "eventId": eventId,
            "userId": userId,
        ])
    }

    static func userMessage(for error: Error) -> String {
        let text = (error as NSError).localizedDescription
        let lower = text.lowercased()
        if text.uppercased().contains("NOT FOUND") {
            return "MyPicsRoom's event service needs to be updated. Deploy the latest Firebase Functions, then try again."
        }
        if lower.contains("changed on another device") || lower.contains("refresh before saving") {
            return "This event changed on another device. Go back, reopen the event, and apply your edit again."
        }
        if let appError = error as? AppError { return appError.userMessage }
        return text
    }

    private static func datePayload(for event: Event) -> [String: Any] {
        let timeZone = event.photoWindowTimeZone ?? .current
        var result: [String: Any] = [
            "startsAtMillis": millis(event.startsAt),
            "endsAtMillis": millis(event.endsAt),
            "startsAtOffsetMinutes": offsetMinutes(for: event.startsAt, in: timeZone),
            "endsAtOffsetMinutes": offsetMinutes(for: event.endsAt, in: timeZone),
            "nowOffsetMinutes": offsetMinutes(for: Date(), in: timeZone),
        ]
        if event.photoWindowVersion == Event.canonicalPhotoWindowVersion,
           let timeZoneId = event.photoWindowTimeZoneId,
           !timeZoneId.isEmpty {
            result["photoWindowVersion"] = Event.canonicalPhotoWindowVersion
            result["photoWindowTimeZoneId"] = timeZoneId
        }
        return result
    }

    private static func offsetMinutes(for date: Date, in timeZone: TimeZone) -> Int {
        timeZone.secondsFromGMT(for: date) / 60
    }

    private static func millis(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    @MainActor
    private static func call(_ name: String, data: [String: Any]) async throws -> Any {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any, Error>) in
            Functions.functions().httpsCallable(name).call(data) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: result?.data as Any)
            }
        }
    }
}
