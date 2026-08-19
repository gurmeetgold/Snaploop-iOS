import FirebaseFunctions
import Foundation

extension FirebaseEventRepository {
    public func reopenEvent(id: String) async throws {
        try await setOrganizerStatus(id: id, status: .active)
    }

    public func moveEventToDeleted(id: String) async throws {
        try await setOrganizerStatus(id: id, status: .deletedByOrganizer)
    }

    public func restoreEvent(id: String) async throws {
        try await setOrganizerStatus(id: id, status: .active)
    }

    private func setOrganizerStatus(id: String, status: EventStatus) async throws {
        let payload: [String: Any] = [
            "eventId": id,
            "status": status.rawValue
        ]

        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any, Error>) in
            Functions.functions().httpsCallable("setEventStatus").call(payload) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: result?.data as Any)
            }
        }
    }
}
