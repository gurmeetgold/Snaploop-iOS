import Foundation

/// State of an on-demand original transfer. A requester asks; the source device
/// (possibly offline) uploads the original to temporary storage; the requester
/// downloads via a signed URL; the temp object expires per TTL.
public enum TransferStatus: String, Codable, Sendable {
    case queued
    case sourceNotified = "source_notified"
    case uploading
    case ready
    case downloading
    case completed
    case failed
    case expired

    public var isTerminal: Bool { self == .completed || self == .expired }

    /// Valid next states. The state machine is deliberately narrow so a buggy or
    /// duplicated client message can't drive a job into an impossible state.
    public var allowedNext: Set<TransferStatus> {
        switch self {
        case .queued:        return [.sourceNotified, .failed, .expired]
        case .sourceNotified:return [.uploading, .failed, .expired]
        case .uploading:     return [.ready, .failed]
        case .ready:         return [.downloading, .expired, .failed]
        case .downloading:   return [.completed, .failed]
        case .failed:        return [.queued]      // retry re-queues
        case .completed:     return []
        case .expired:       return []
        }
    }
}

/// The Firestore `transfers/{transferId}` document. Transitions go through
/// `advance(to:)`, which enforces the state machine and is **idempotent** —
/// re-applying the current state is a no-op, so a retried/duplicated message
/// never does double work or corrupts state.
public struct TransferJob: Identifiable, Equatable, Codable, Sendable {
    public let id: String
    public let eventId: String
    public let photoId: String
    public let sourceUserId: String
    public let requestingUserId: String
    public private(set) var status: TransferStatus
    public var temporaryObjectPath: String?
    public let requestedAt: Date
    public var readyAt: Date?
    public var expiresAt: Date?

    public init(
        id: String,
        eventId: String,
        photoId: String,
        sourceUserId: String,
        requestingUserId: String,
        status: TransferStatus = .queued,
        temporaryObjectPath: String? = nil,
        requestedAt: Date,
        readyAt: Date? = nil,
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.eventId = eventId
        self.photoId = photoId
        self.sourceUserId = sourceUserId
        self.requestingUserId = requestingUserId
        self.status = status
        self.temporaryObjectPath = temporaryObjectPath
        self.requestedAt = requestedAt
        self.readyAt = readyAt
        self.expiresAt = expiresAt
    }

    /// Attempts a transition. Idempotent for a same-state request. Throws
    /// `AppError` for an illegal transition.
    public mutating func advance(to next: TransferStatus) throws {
        if next == status { return }                       // idempotent
        guard status.allowedNext.contains(next) else {
            throw AppError.backend(code: "transfer_transition",
                                   message: "Cannot go from \(status.rawValue) to \(next.rawValue)")
        }
        status = next
    }

    /// Human status line for the transfer UI — never technical.
    public func userStatus(sourceName: String) -> String {
        switch status {
        case .queued, .sourceNotified:
            return "Waiting for the original from \(sourceName)'s phone…"
        case .uploading:
            return "Getting it from \(sourceName)'s phone…"
        case .ready:
            return "Ready to download"
        case .downloading:
            return "Downloading…"
        case .completed:
            return "Saved"
        case .failed:
            return "Couldn't get this one. We'll try again."
        case .expired:
            return "This download expired. Tap to request it again."
        }
    }
}
