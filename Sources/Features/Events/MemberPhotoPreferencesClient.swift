import FirebaseFunctions
import Foundation

struct MemberPhotoPreferences: Equatable, Sendable {
    let sharingEnabled: Bool
    let includeOwnMatches: Bool
    let revisionToken: String
}

enum MemberPhotoPreferencesClient {
    @MainActor
    static func load(eventId: String) async throws -> MemberPhotoPreferences {
        let raw = try await call("getMemberPhotoPreferences", data: ["eventId": eventId])
        guard let data = raw as? [String: Any] else {
            throw AppError.decoding("Photo preferences returned malformed data")
        }

        let sharingUpdated = millisString(data["sharingUpdatedAtMillis"])
        let ownUpdated = millisString(data["ownMatchesUpdatedAtMillis"])
        return MemberPhotoPreferences(
            sharingEnabled: data["sharingEnabled"] as? Bool ?? true,
            includeOwnMatches: data["includeOwnMatches"] as? Bool ?? false,
            revisionToken: "\(sharingUpdated)-\(ownUpdated)"
        )
    }

    @MainActor
    static func setIncludeOwnMatches(eventId: String, enabled: Bool) async throws {
        _ = try await call("setOwnPhotoVisibility", data: [
            "eventId": eventId,
            "enabled": enabled,
        ])
    }

    private static func millisString(_ value: Any?) -> String {
        if let n = value as? NSNumber { return String(n.int64Value) }
        if let d = value as? Double { return String(Int64(d)) }
        if let i = value as? Int { return String(i) }
        return "0"
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
