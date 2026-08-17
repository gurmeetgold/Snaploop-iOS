import FirebaseFirestore
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
        try await Firestore.firestore()
            .collection("events")
            .document(id)
            .updateData([
                "status": status.rawValue,
                "updatedAt": FieldValue.serverTimestamp()
            ])
    }
}
