import FirebaseFirestore
import Foundation

struct EventNotification: Identifiable, Sendable {
    let id: String
    let eventId: String
    let title: String
    let body: String
    let createdAt: Date
}

enum EventNotificationClient {
    @MainActor
    static func unread(userId: String) async throws -> [EventNotification] {
        guard AppEnvironment.useLiveServices else { return [] }
        let snapshot = try await Firestore.firestore()
            .collection("users")
            .document(userId)
            .collection("notifications")
            .whereField("read", isEqualTo: false)
            .limit(to: 20)
            .getDocuments()

        return snapshot.documents.compactMap { document in
            let data = document.data()
            guard let eventId = data["eventId"] as? String,
                  let title = data["title"] as? String,
                  let body = data["body"] as? String else { return nil }
            let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? .distantPast
            return EventNotification(
                id: document.documentID,
                eventId: eventId,
                title: title,
                body: body,
                createdAt: createdAt
            )
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    @MainActor
    static func markRead(userId: String, notificationId: String) async throws {
        guard AppEnvironment.useLiveServices else { return }
        try await Firestore.firestore()
            .collection("users")
            .document(userId)
            .collection("notifications")
            .document(notificationId)
            .updateData(["read": true])
    }
}
