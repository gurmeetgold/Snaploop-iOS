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
            "startsAtMillis": event.startsAt.timeIntervalSince1970 * 1000,
            "endsAtMillis": event.endsAt.timeIntervalSince1970 * 1000,
            "status": event.status.rawValue,
            "createdAtMillis": event.createdAt.timeIntervalSince1970 * 1000,
            "updatedAtMillis": event.updatedAt.timeIntervalSince1970 * 1000,
        ]
        if let cover = event.coverImagePath { data["coverImagePath"] = cover }
        if let location = event.locationName { data["locationName"] = location }
        _ = try await call("createEvent", data: data)
    }

    @MainActor
    static func join(eventId: String) async throws {
        _ = try await call("joinEvent", data: ["eventId": eventId])
    }

    @MainActor
    static func update(_ event: Event, expectedUpdatedAt: Date? = nil) async throws -> Bool {
        var data: [String: Any] = [
            "eventId": event.id,
            "name": event.name,
            "category": event.category.rawValue,
            "coverImagePath": NSNull(),
            "locationName": NSNull(),
            "startsAtMillis": event.startsAt.timeIntervalSince1970 * 1000,
            "endsAtMillis": event.endsAt.timeIntervalSince1970 * 1000,
        ]
        if let expectedUpdatedAt {
            data["expectedUpdatedAtMillis"] = expectedUpdatedAt.timeIntervalSince1970 * 1000
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
