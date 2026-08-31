import FirebaseFunctions
import Foundation

struct MemberPhotoPreferences: Equatable, Sendable {
    let sharingEnabled: Bool
    let includeOwnMatches: Bool

    /// Combined matching/publication revision. The coordinator parses the source
    /// sharing and own-photo visibility components independently:
    /// - sharing generation changes replay all previously published positives
    ///   because sharing OFF removes this source's server photo rows;
    /// - own-photo visibility changes invalidate only the current user's own
    ///   recipient cursor, so OFF→ON can restore cached self matches even when no
    ///   scan occurred while the setting was OFF.
    /// The combined token also makes automatic sync wake immediately for either
    /// preference change without creating a separate trigger channel.
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

        let serverSharingRevision = normalizedString(data["sharingRevision"])
        let sharingRevision = serverSharingRevision
            .map { "id:\($0)" }
            ?? "legacy:\(sharingUpdated)"

        let serverOwnRevision = normalizedString(data["ownMatchesRevision"])
        let ownRevision = serverOwnRevision
            .map { "id:\($0)" }
            ?? "legacy:\(ownUpdated)"

        return MemberPhotoPreferences(
            sharingEnabled: data["sharingEnabled"] as? Bool ?? true,
            includeOwnMatches: data["includeOwnMatches"] as? Bool ?? false,
            revisionToken: "share=\(sharingRevision);own=\(ownRevision)"
        )
    }

    @MainActor
    static func setIncludeOwnMatches(eventId: String, enabled: Bool) async throws {
        _ = try await call("setOwnPhotoVisibility", data: [
            "eventId": eventId,
            "enabled": enabled,
        ])
    }

    @MainActor
    static func disableOwnMatchesEverywhere() async throws {
        _ = try await call("disableOwnMatchesEverywhere", data: [:])
    }

    private static func normalizedString(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
