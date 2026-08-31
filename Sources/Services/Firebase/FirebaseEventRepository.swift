import Foundation
import FirebaseFirestore
import FirebaseFunctions

/// Live Firebase implementation of EventRepository.
///
/// Trusted membership transitions, event edits, lifecycle changes, sharing
/// changes and invite resolution are performed through callable Cloud Functions.
/// Member-authorized reads use Firestore directly unless the data needs a
/// server-curated privacy boundary.
public final class FirebaseEventRepository: EventRepository, @unchecked Sendable {

    private let db: Firestore
    private let functions: Functions

    public init(
        db: Firestore = Firestore.firestore(),
        functions: Functions = Functions.functions()
    ) {
        self.db = db
        self.functions = functions
    }

    // MARK: - Event CRUD

    public func createEvent(_ event: Event) async throws {
        var payload: [String: Any] = [
            "id": event.id,
            "joinCode": event.joinCode,
            "inviteToken": event.inviteToken,
            "creatorUserId": event.creatorUserId,
            "name": event.name,
            "category": event.category.rawValue,
            "startsAtMillis": Self.millis(event.startsAt),
            "endsAtMillis": Self.millis(event.endsAt),
            "startsAtOffsetMinutes": Self.offsetMinutes(for: event.startsAt),
            "endsAtOffsetMinutes": Self.offsetMinutes(for: event.endsAt),
            "nowOffsetMinutes": Self.offsetMinutes(for: Date()),
            "status": event.status.rawValue,
            "createdAtMillis": Self.millis(event.createdAt),
            "updatedAtMillis": Self.millis(event.updatedAt)
        ]
        payload["coverImagePath"] = event.coverImagePath ?? NSNull()
        payload["locationName"] = event.locationName ?? NSNull()

        _ = try await call("createEvent", data: payload)
    }

    public func fetchEvent(id: String) async throws -> Event {
        do {
            let snapshot = try await eventRef(id).getDocument()
            guard snapshot.exists, let data = snapshot.data() else {
                throw AppError.eventNotFound
            }
            return try Self.decodeEvent(id: snapshot.documentID, data: data)
        } catch let error as AppError {
            throw error
        } catch {
            throw Self.mapFirestoreError(error)
        }
    }

    public func fetchEvent(joinCode: JoinCode) async throws -> Event {
        let raw = try await call("resolveInvite", data: ["joinCode": joinCode.value])
        return try Self.decodeCallableEvent(raw)
    }

    public func fetchEvent(inviteToken: InviteToken) async throws -> Event {
        let raw = try await call("resolveInvite", data: ["inviteToken": inviteToken.value])
        return try Self.decodeCallableEvent(raw)
    }

    public func updateEventDetails(
        id: String,
        name: String,
        category: EventCategory,
        coverImagePath: String?,
        locationName: String?
    ) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AppError.invalidEventName }

        var payload: [String: Any] = [
            "eventId": id,
            "name": trimmed,
            "category": category.rawValue
        ]
        payload["coverImagePath"] = coverImagePath ?? NSNull()
        payload["locationName"] = locationName ?? NSNull()
        _ = try await call("updateEventManaged", data: payload)
    }

    public func updateEventDates(id: String, startsAt: Date, endsAt: Date) async throws {
        guard endsAt >= startsAt else { throw AppError.invalidEventDates }
        _ = try await call(
            "updateEventManaged",
            data: [
                "eventId": id,
                "startsAtMillis": Self.millis(startsAt),
                "endsAtMillis": Self.millis(endsAt),
                "startsAtOffsetMinutes": Self.offsetMinutes(for: startsAt),
                "endsAtOffsetMinutes": Self.offsetMinutes(for: endsAt),
                "nowOffsetMinutes": Self.offsetMinutes(for: Date())
            ]
        )
    }

    public func endEvent(id: String) async throws {
        _ = try await call(
            "setEventStatus",
            data: [
                "eventId": id,
                "status": EventStatus.endedByOrganizer.rawValue
            ]
        )
    }

    // MARK: - Membership

    public func addMember(eventId: String, member: EventMember) async throws {
        _ = try await call("joinEvent", data: ["eventId": eventId])
    }

    public func removeMember(eventId: String, userId: String) async throws {
        _ = try await call("leaveEvent", data: ["eventId": eventId, "userId": userId])
    }

    public func setSharing(eventId: String, userId: String, enabled: Bool) async throws {
        _ = try await call(
            "setSharing",
            data: [
                "eventId": eventId,
                "userId": userId,
                "enabled": enabled
            ]
        )
    }

    /// Roster names are resolved server-side so the app never needs direct read
    /// access to the biometric participant documents.
    public func members(eventId: String) async throws -> [EventMember] {
        let raw = try await call("listEventMembers", data: ["eventId": eventId])
        guard
            let wrapper = raw as? [String: Any],
            let rows = wrapper["members"] as? [[String: Any]]
        else {
            throw AppError.decoding("listEventMembers returned malformed data")
        }
        return try rows.map(Self.decodeCallableMember).sorted { $0.joinedAt < $1.joinedAt }
    }

    public func join(eventId: String, participant: EventParticipant) async throws {
        _ = try await call("joinEvent", data: ["eventId": eventId])
    }

    /// Kept for legacy protocol compatibility. New UI should use `members()` for
    /// roster identity and `listEventFaceProfiles` for matching descriptors.
    public func participants(eventId: String) async throws -> [EventParticipant] {
        do {
            let snapshot = try await eventRef(eventId)
                .collection("participants")
                .getDocuments()

            return try snapshot.documents
                .map { try Self.decodeParticipant(id: $0.documentID, data: $0.data()) }
                .sorted { $0.joinedAt < $1.joinedAt }
        } catch {
            throw Self.mapFirestoreError(error)
        }
    }

    public func events(forUserId userId: String) async throws -> [Event] {
        do {
            let refs = try await db.collection("users")
                .document(userId)
                .collection("eventRefs")
                .getDocuments()

            var result: [Event] = []
            result.reserveCapacity(refs.documents.count)

            for refDoc in refs.documents {
                let eventId = (refDoc.data()["eventId"] as? String) ?? refDoc.documentID
                do {
                    let event = try await fetchEvent(id: eventId)
                    result.append(event)
                } catch AppError.eventNotFound {
                    continue
                } catch AppError.notAMember {
                    continue
                }
            }

            return result.sorted { $0.startsAt > $1.startsAt }
        } catch let error as AppError {
            throw error
        } catch {
            throw Self.mapFirestoreError(error)
        }
    }

    // MARK: - Callable helper

    private func call(_ name: String, data: [String: Any]) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            functions.httpsCallable(name).call(data) { result, error in
                if let error {
                    continuation.resume(throwing: Self.mapFunctionsError(error))
                    return
                }

                guard let result else {
                    continuation.resume(
                        throwing: AppError.backend(
                            code: "empty_function_result",
                            message: "\(name) returned no result"
                        )
                    )
                    return
                }

                continuation.resume(returning: result.data)
            }
        }
    }

    // MARK: - Firestore references

    private func eventRef(_ id: String) -> DocumentReference {
        db.collection("events").document(id)
    }

    // MARK: - Decoding

    private static func decodeCallableMember(_ data: [String: Any]) throws -> EventMember {
        guard
            let userId = data["userId"] as? String,
            let roleRaw = data["role"] as? String,
            let role = EventMember.Role(rawValue: roleRaw),
            let joinedAt = dateFromMillis(data["joinedAtMillis"])
        else {
            throw AppError.decoding("Event member is missing required fields")
        }

        return EventMember(
            userId: userId,
            membershipId: normalizedOptionalString(data["membershipId"]),
            displayName: nullableString(data["displayName"]),
            role: role,
            joinedAt: joinedAt,
            sharingEnabled: data["sharingEnabled"] as? Bool ?? true,
            lastSyncAt: dateFromMillis(data["lastSyncAtMillis"]),
            faceTemplateVersion:
                (data["faceTemplateVersion"] as? NSNumber)?.intValue
                ?? data["faceTemplateVersion"] as? Int
                ?? 1
        )
    }

    private static func decodeCallableEvent(_ raw: Any) throws -> Event {
        guard
            let wrapper = raw as? [String: Any],
            let event = wrapper["event"] as? [String: Any],
            let id = event["id"] as? String
        else {
            throw AppError.decoding("resolveInvite returned malformed event data")
        }

        guard
            let joinCode = event["joinCode"] as? String,
            let inviteToken = event["inviteToken"] as? String,
            let creatorUserId = event["creatorUserId"] as? String,
            let name = event["name"] as? String,
            let categoryRaw = event["category"] as? String,
            let category = EventCategory(rawValue: categoryRaw),
            let statusRaw = event["status"] as? String,
            let status = EventStatus(rawValue: statusRaw),
            let startsAt = dateFromMillis(event["startsAtMillis"]),
            let endsAt = dateFromMillis(event["endsAtMillis"]),
            let createdAt = dateFromMillis(event["createdAtMillis"]),
            let updatedAt = dateFromMillis(event["updatedAtMillis"])
        else {
            throw AppError.decoding("resolveInvite event is missing required fields")
        }

        return Event(
            id: id,
            joinCode: joinCode,
            inviteToken: inviteToken,
            creatorUserId: creatorUserId,
            name: name,
            category: category,
            coverImagePath: nullableString(event["coverImagePath"]),
            locationName: nullableString(event["locationName"]),
            startsAt: startsAt,
            endsAt: endsAt,
            status: status,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private static func decodeEvent(id: String, data: [String: Any]) throws -> Event {
        guard
            let joinCode = data["joinCode"] as? String,
            let inviteToken = data["inviteToken"] as? String,
            let creatorUserId = data["creatorUserId"] as? String,
            let name = data["name"] as? String,
            let categoryRaw = data["category"] as? String,
            let category = EventCategory(rawValue: categoryRaw),
            let statusRaw = data["status"] as? String,
            let status = EventStatus(rawValue: statusRaw),
            let startsAt = timestampDate(data["startsAt"]),
            let endsAt = timestampDate(data["endsAt"]),
            let createdAt = timestampDate(data["createdAt"])
        else {
            throw AppError.decoding("events/\(id) is missing required fields")
        }

        let updatedAt = timestampDate(data["updatedAt"]) ?? createdAt

        return Event(
            id: id,
            joinCode: joinCode,
            inviteToken: inviteToken,
            creatorUserId: creatorUserId,
            name: name,
            category: category,
            coverImagePath: data["coverImagePath"] as? String,
            locationName: data["locationName"] as? String,
            startsAt: startsAt,
            endsAt: endsAt,
            status: status,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private static func decodeParticipant(id: String, data: [String: Any]) throws -> EventParticipant {
        let vector: [Float]
        if let numbers = data["faceEmbedding"] as? [NSNumber] {
            vector = numbers.map(\.floatValue)
        } else if let doubles = data["faceEmbedding"] as? [Double] {
            vector = doubles.map(Float.init)
        } else {
            throw AppError.decoding("participant \(id) missing faceEmbedding")
        }

        guard
            let userId = data["userId"] as? String,
            !vector.isEmpty,
            let joinedAt = timestampDate(data["joinedAt"])
        else {
            throw AppError.decoding("participant \(id) is missing required fields")
        }

        var templates: [FaceTemplate] = []
        if let rawTemplates = data["faceTemplates"] as? [[String: Any]] {
            templates = rawTemplates.compactMap { item in
                let rawVector: [Float]
                if let numbers = item["embedding"] as? [NSNumber] {
                    rawVector = numbers.map(\.floatValue)
                } else if let doubles = item["embedding"] as? [Double] {
                    rawVector = doubles.map(Float.init)
                } else {
                    return nil
                }

                guard
                    let embedding = FaceEmbedding(rawVector),
                    let poseRaw = item["pose"] as? String,
                    let pose = FaceTemplate.Pose(rawValue: poseRaw)
                else { return nil }

                return FaceTemplate(
                    id: item["id"] as? String ?? UUID().uuidString,
                    embedding: embedding,
                    pose: pose,
                    quality:
                        (item["quality"] as? NSNumber)?.doubleValue
                        ?? item["quality"] as? Double
                        ?? 1.0,
                    createdAt: timestampDate(item["createdAt"]) ?? joinedAt
                )
            }
        }

        return EventParticipant(
            userId: userId,
            membershipId: normalizedOptionalString(data["membershipId"]),
            displayName: data["displayName"] as? String,
            phoneNumber: nil,
            faceEmbedding: FaceEmbedding(normalized: vector),
            faceTemplates: templates,
            faceProfileVersion:
                (data["faceProfileVersion"] as? NSNumber)?.intValue
                ?? data["faceProfileVersion"] as? Int
                ?? 1,
            joinedAt: joinedAt
        )
    }

    private static func timestampDate(_ value: Any?) -> Date? {
        if let timestamp = value as? Timestamp { return timestamp.dateValue() }
        if let date = value as? Date { return date }
        return nil
    }

    private static func dateFromMillis(_ value: Any?) -> Date? {
        let millis: Double?
        if let n = value as? NSNumber { millis = n.doubleValue }
        else if let d = value as? Double { millis = d }
        else if let i = value as? Int { millis = Double(i) }
        else { millis = nil }
        guard let millis else { return nil }
        return Date(timeIntervalSince1970: millis / 1000.0)
    }

    private static func nullableString(_ value: Any?) -> String? {
        if value is NSNull { return nil }
        return value as? String
    }

    private static func normalizedOptionalString(_ value: Any?) -> String? {
        guard let raw = nullableString(value)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return raw
    }

    private static func millis(_ date: Date) -> Double {
        date.timeIntervalSince1970 * 1000.0
    }

    private static func offsetMinutes(for date: Date) -> Int {
        TimeZone.current.secondsFromGMT(for: date) / 60
    }

    // MARK: - Error mapping

    private static func mapFunctionsError(_ error: Error) -> AppError {
        let nsError = error as NSError

        guard nsError.domain == FunctionsErrorDomain else {
            if nsError.domain == NSURLErrorDomain {
                return .network(underlying: nsError.localizedDescription)
            }
            return .backend(code: "function_\(nsError.code)", message: nsError.localizedDescription)
        }

        guard let code = FunctionsErrorCode(rawValue: nsError.code) else {
            return .backend(code: "function_\(nsError.code)", message: nsError.localizedDescription)
        }

        switch code {
        case .unauthenticated:
            return .notAuthenticated
        case .notFound:
            return .eventNotFound
        case .resourceExhausted:
            return .eventFull
        case .failedPrecondition:
            let message = nsError.localizedDescription.lowercased()
            if message.contains("ended") || message.contains("expired") { return .eventExpired }
            if message.contains("face") { return .faceEmbeddingFailed }
            return .backend(code: "failed_precondition", message: nsError.localizedDescription)
        case .invalidArgument:
            let message = nsError.localizedDescription.lowercased()
            if message.contains("join code") { return .invalidJoinCode }
            return .backend(code: "invalid_argument", message: nsError.localizedDescription)
        case .permissionDenied:
            return .notAMember
        case .alreadyExists:
            return .backend(code: "event_identity_collision", message: "Please try creating the event again.")
        default:
            return .backend(code: "\(code.rawValue)", message: nsError.localizedDescription)
        }
    }

    private static func mapFirestoreError(_ error: Error) -> AppError {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return .network(underlying: nsError.localizedDescription)
        }
        if nsError.code == 7 { return .notAMember }
        return .backend(code: "firestore_\(nsError.code)", message: nsError.localizedDescription)
    }
}
