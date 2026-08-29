import FirebaseFunctions
import Foundation

struct EventInviteDelivery: Sendable {
    enum Kind: String, Sendable { case inApp = "in_app", sms }
    let kind: Kind
    let phoneNumber: String
}

struct EventInviteStatusRow: Identifiable, Sendable {
    let id = UUID()
    let phoneNumber: String
    let status: String
    let delivery: String
}

struct EventInvitePreview: Sendable {
    let inviterName: String?
}

enum EventInviteClient {
    @MainActor
    static func invite(eventId: String, phoneNumber: String) async throws -> EventInviteDelivery {
        let data = try await call("inviteByPhone", data: [
            "eventId": eventId,
            "phoneNumber": phoneNumber,
        ])
        guard let dict = data as? [String: Any],
              let deliveryRaw = dict["delivery"] as? String,
              let kind = EventInviteDelivery.Kind(rawValue: deliveryRaw) else {
            throw AppError.backend(code: "invalid_response", message: "Invite service returned an invalid response.")
        }
        return EventInviteDelivery(kind: kind, phoneNumber: (dict["phoneNumber"] as? String) ?? phoneNumber)
    }

    @MainActor
    static func preview(route: DeepLinkRoute) async throws -> EventInvitePreview {
        let kind: String
        let value: String
        switch route {
        case .joinEventByToken(let token):
            kind = "e"
            value = token.value
        case .joinEventByCode(let code):
            kind = "c"
            value = code.value
        }

        let data = try await call("resolveInvitePreview", data: ["kind": kind, "value": value])
        guard let dict = data as? [String: Any] else {
            throw AppError.backend(code: "invalid_response", message: "Invite preview returned an invalid response.")
        }
        let raw = (dict["inviterName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return EventInvitePreview(inviterName: raw?.isEmpty == false ? raw : nil)
    }

    @MainActor
    static func nextPendingRoute() async throws -> DeepLinkRoute? {
        let data = try await call("nextPendingInvite", data: [:])
        guard let dict = data as? [String: Any] else { return nil }
        if dict["invite"] is NSNull { return nil }
        guard let tokenRaw = dict["inviteToken"] as? String,
              let token = InviteToken(tokenRaw) else { return nil }
        return .joinEventByToken(token)
    }

    @MainActor
    static func list(eventId: String) async throws -> [EventInviteStatusRow] {
        let data = try await call("listEventInvites", data: ["eventId": eventId])
        guard let dict = data as? [String: Any], let rows = dict["invites"] as? [[String: Any]] else { return [] }
        return rows.map {
            EventInviteStatusRow(
                phoneNumber: ($0["phoneNumber"] as? String) ?? "",
                status: ($0["status"] as? String) ?? "invited",
                delivery: ($0["delivery"] as? String) ?? "sms"
            )
        }
    }

    @MainActor
    static func decline(eventId: String) async throws {
        _ = try await call("declineEventInvite", data: ["eventId": eventId])
    }

    @MainActor
    static func revoke(eventId: String, phoneNumber: String) async throws {
        _ = try await call("revokeEventInvite", data: [
            "eventId": eventId,
            "phoneNumber": phoneNumber,
        ])
    }

    static func userMessage(for error: Error) -> String {
        let text = (error as NSError).localizedDescription
        if text.uppercased().contains("NOT FOUND") {
            return "SnapLoop's event service needs to be updated. Deploy the latest Firebase Functions, then try again."
        }
        if let appError = error as? AppError { return appError.userMessage }
        return text
    }

    @MainActor
    private static func call(_ name: String, data: [String: Any]) async throws -> Any {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any, Error>) in
            Functions.functions().httpsCallable(name).call(data) { result, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: result?.data as Any)
            }
        }
    }
}
