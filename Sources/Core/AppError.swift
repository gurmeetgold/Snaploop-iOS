import Foundation

/// A single typed error surface for the whole app. Every service throws these
/// so higher layers can switch exhaustively and map to human copy without ever
/// leaking a raw `NSError` into the UI.
public enum AppError: Error, Equatable, Sendable {
    case notAuthenticated
    case invalidPhoneNumber
    case invalidVerificationCode
    case verificationExpired
    case photoLibraryAccessDenied
    case cameraAccessDenied
    case noFaceDetectedInSelfie
    case multipleFacesInSelfie
    case faceEmbeddingFailed
    case faceRecognitionNotReady
    case eventNotFound
    case eventExpired
    case eventFull
    case invalidEventName
    case invalidEventDates
    case notAMember
    case eventDurationTooLong(maxDays: Int)
    case invalidJoinCode
    case thumbnailEncodingFailed
    case downloadLinkExpired
    case originalUnavailable
    case network(underlying: String)
    case backend(code: String, message: String)
    case decoding(String)
    case unknown(String)
}

public extension AppError {
    var userMessage: String {
        switch self {
        case .notAuthenticated:
            return "Please sign in to continue."
        case .invalidPhoneNumber:
            return "That phone number doesn't look right. Please check and try again."
        case .invalidVerificationCode:
            return "That code isn't correct. Please try again."
        case .verificationExpired:
            return "That code expired. We'll send you a new one."
        case .photoLibraryAccessDenied:
            return "MyPicsTube needs access to your photos to find pictures of you. You can enable it in Settings."
        case .cameraAccessDenied:
            return "MyPicsTube needs camera access to set up your face. You can enable it in Settings."
        case .noFaceDetectedInSelfie:
            return "We couldn't find a face in that photo. Try again in better light, facing the camera."
        case .multipleFacesInSelfie:
            return "Make sure it's just you in the photo, then try again."
        case .faceEmbeddingFailed:
            return "Something went wrong setting up your face. Please try again."
        case .faceRecognitionNotReady:
            return "Camera matching is not ready for this build. Your photos have not been marked as scanned."
        case .eventNotFound:
            return "We couldn't find that event."
        case .eventExpired:
            return "This event has ended."
        case .eventFull:
            return "This event is full."
        case .invalidEventName:
            return "Please give your event a name."
        case .invalidEventDates:
            return "Please pick a valid start and end date."
        case .notAMember:
            return "You need to join this event first."
        case .eventDurationTooLong(let maxDays):
            return "Events can run for up to \(maxDays) days."
        case .invalidJoinCode:
            return "That code didn't work. Double-check it and try again."
        case .thumbnailEncodingFailed, .originalUnavailable:
            return "We couldn't prepare that photo. Please try again."
        case .downloadLinkExpired:
            return "That link expired. Try again to get a fresh one."
        case .network:
            return "You appear to be offline. Please check your connection and try again."
        case .backend, .decoding, .unknown:
            return "Something went wrong. Please try again."
        }
    }
}
