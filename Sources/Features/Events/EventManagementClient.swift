import FirebaseFunctions
import Foundation

/// Thin client for trusted event mutations that must be enforced server-side.
/// Existing repository reads remain unchanged.
enum EventManagementClient {
    @MainActor
    static func create(_ event: Event) async throws {
        _ = try await call("createEventMVP", data: [
            "id": event.id,
            "joinCode": event.joinCode,
            "inviteToken": event.inviteToken,
            "creatorUserId": event.creatorUserId,
            "name": event.name,
            "category": event.category.rawValue,
            "coverImagePath": event.coverImagePath as Any,
            "locationName": event.locationName as Any,
            "startsAtMillis": event.startsAt.timeIntervalSince1970 * 1000,
            "endsAtMillis": event.endsAt.timeIntervalSince1970 * 1000,
            "status": event.status.rawValue,
            "createdAtMillis": event.createdAt.timeIntervalSince1970 * 1000,
            "updatedAtMillis": event.updatedAt.timeIntervalSince1970 * 1000,
        ])
    }

    @MainActor
    static func join(eventId: String) async throws {
        _ = try await call("joinEventManaged", data: ["eventId": eventId])
    }

    @MainActor
    static func update(_ event: Event) async throws -> Bool {
        let raw = try await call("updateEventManaged", data: [
            "eventId": event.id,
            "name": event.name,
            "category": event.category.rawValue,
            "coverImagePath": event.coverImagePath as Any,
            "locationName": event.locationName as Any,
            "startsAtMillis": event.startsAt.timeIntervalSince1970 * 1000,
            "endsAtMillis": event.endsAt.timeIntervalSince1970 * 1000,
        ])
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
        _ = try await call("manageEventMember", data: [
            "eventId": eventId,
            "userId": userId,
            "action": "remove",
        ])
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
