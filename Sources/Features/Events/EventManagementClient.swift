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
        // Stable alias exists on both the older backend and the managed rollout.
        _ = try await call("createEvent", data: data)
    }

    @MainActor
    static func join(eventId: String) async throws {
        // Stable alias exists on both the older backend and the managed rollout.
        _ = try await call("joinEvent", data: ["eventId": eventId])
    }

    @MainActor
    static func update(_ event: Event) async throws -> Bool {
        var data: [String: Any] = [
            "eventId": event.id,
            "name": event.name,
            "category": event.category.rawValue,
            "coverImagePath": NSNull(),
            "locationName": NSNull(),
            "startsAtMillis": event.startsAt.timeIntervalSince1970 * 1000,
            "endsAtMillis": event.endsAt.timeIntervalSince1970 * 1000,
        ]
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
        // `leaveEvent` is deliberately kept as the stable public callable. The
        // latest backend overrides it with the managed implementation, while an
        // older deployed backend can still remove/leave without NOT_FOUND.
        _ = try await call("leaveEvent", data: [
            "eventId": eventId,
            "userId": userId,
        ])
    }

    static func userMessage(for error: Error) -> String {
        let text = (error as NSError).localizedDescription
        if text.uppercased().contains("NOT FOUND") {
            return "MyPicsRoom's event service needs to be updated. Deploy the latest Firebase Functions, then try again."
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
