import FirebaseFirestore
import Foundation

extension FirebaseEventRepository {
    public func archiveEvent(id: String) async throws {
        do {
            try await Firestore.firestore().collection("events").document(id).updateData([
                "status": EventStatus.archived.rawValue,
                "updatedAt": FieldValue.serverTimestamp()
            ])
        } catch {
            throw AppError.backend(code: "archive_event_failed", message: (error as NSError).localizedDescription)
        }
    }

    public func restoreEvent(id: String) async throws {
        do {
            try await Firestore.firestore().collection("events").document(id).updateData([
                "status": EventStatus.active.rawValue,
                "updatedAt": FieldValue.serverTimestamp()
            ])
        } catch {
            throw AppError.backend(code: "restore_event_failed", message: (error as NSError).localizedDescription)
        }
    }
}
