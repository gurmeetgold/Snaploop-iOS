import Foundation
import ImageIO
import Photos
import UIKit
import UniformTypeIdentifiers

/// Thread-safe one-shot bridge for PhotoKit's callback APIs. PhotoKit may deliver
/// degraded + final callbacks and cancellation/error callbacks can race with task
/// cancellation. Only the first terminal outcome is allowed to resume Swift's
/// checked continuation.
private final class PhotoRequestGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var requestID: PHImageRequestID?
    private var cancelled = false
    private var finished = false

    /// Returns false when cancellation happened before the continuation was
    /// installed. In that case this method resumes it with CancellationError.
    func install(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        lock.lock()
        if cancelled {
            finished = true
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return false
        }
        if finished {
            lock.unlock()
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    /// Returns true when the underlying PhotoKit request should be cancelled
    /// immediately because task cancellation raced request creation.
    func setRequestID(_ requestID: PHImageRequestID) -> Bool {
        lock.lock()
        self.requestID = requestID
        let shouldCancel = cancelled
        lock.unlock()
        return shouldCancel
    }

    func succeed(_ value: Value) {
        finish(.success(value))
    }

    func fail(_ error: Error) {
        finish(.failure(error))
    }

    /// Resumes the Swift continuation immediately and returns the PhotoKit request
    /// ID, if one already exists, so the caller can cancel underlying image work.
    func cancel() -> PHImageRequestID? {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return nil
        }
        cancelled = true
        let requestID = requestID
        let continuation = continuation
        if continuation != nil {
            finished = true
            self.continuation = nil
        }
        lock.unlock()

        continuation?.resume(throwing: CancellationError())
        return requestID
    }

    private func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        guard let continuation else { return }
        switch result {
        case .success(let value): continuation.resume(returning: value)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }
}

/// Production PhotoKit implementation. Reads only the current device's library.
public final class PhotoKitPhotoLibraryService: PhotoLibraryService, @unchecked Sendable {
    private let imageManager: PHImageManager

    public init(imageManager: PHImageManager = .default()) {
        self.imageManager = imageManager
    }

    public func authorizationStatus() -> PhotoAuthorization {
        Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    public func requestAuthorization() async -> PhotoAuthorization {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return Self.map(status)
    }

    public func assets(in range: ClosedRange<Date>) async throws -> [PhotoAsset] {
        guard authorizationStatus().canRead else {
            throw AppError.photoLibraryAccessDenied
        }

        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "creationDate >= %@ AND creationDate <= %@",
            range.lowerBound as NSDate,
            range.upperBound as NSDate
        )
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]

        let result = PHAsset.fetchAssets(with: .image, options: options)
        var values: [PhotoAsset] = []
        values.reserveCapacity(result.count)

        result.enumerateObjects { asset, _, _ in
            guard let date = asset.creationDate else { return }
            values.append(PhotoAsset(id: asset.localIdentifier, creationDate: date))
        }
        return values
    }

    /// Returns a bounded working JPEG without first materializing the full
    /// original asset in memory. This is the path used by face recognition.
    public func imageData(for assetId: String, maxPixelSize: Int) async throws -> Data {
        guard authorizationStatus().canRead else {
            throw AppError.photoLibraryAccessDenied
        }
        try Task.checkCancellation()

        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil)
        guard let asset = fetch.firstObject else {
            throw AppError.originalUnavailable
        }

        let longest = CGFloat(max(1, maxPixelSize))
        let pixelWidth = max(CGFloat(asset.pixelWidth), 1)
        let pixelHeight = max(CGFloat(asset.pixelHeight), 1)
        let scale = min(1, longest / max(pixelWidth, pixelHeight))
        let targetSize = CGSize(
            width: max(1, pixelWidth * scale),
            height: max(1, pixelHeight * scale)
        )

        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.version = .current
        options.isNetworkAccessAllowed = true

        let gate = PhotoRequestGate<UIImage>()
        let image: UIImage = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard gate.install(continuation) else { return }

                let requestID = imageManager.requestImage(
                    for: asset,
                    targetSize: targetSize,
                    contentMode: .aspectFit,
                    options: options
                ) { image, info in
                    if let cancelled = info?[PHImageCancelledKey] as? Bool, cancelled {
                        gate.fail(CancellationError())
                        return
                    }
                    if let error = info?[PHImageErrorKey] as? Error {
                        gate.fail(error)
                        return
                    }
                    if let degraded = info?[PHImageResultIsDegradedKey] as? Bool, degraded {
                        return
                    }
                    guard let image else {
                        gate.fail(AppError.originalUnavailable)
                        return
                    }
                    gate.succeed(image)
                }

                if gate.setRequestID(requestID) {
                    imageManager.cancelImageRequest(requestID)
                }
            }
        } onCancel: {
            if let requestID = gate.cancel() {
                self.imageManager.cancelImageRequest(requestID)
            }
        }

        try Task.checkCancellation()
        guard let cgImage = image.cgImage else {
            throw AppError.thumbnailEncodingFailed
        }
        return try Self.encodeJPEG(cgImage, quality: 0.92)
    }

    /// Full-resolution original access is reserved for explicit original-photo
    /// workflows. Camera sync must use `imageData(for:maxPixelSize:)` instead.
    public func originalImageData(for assetId: String) async throws -> Data {
        guard authorizationStatus().canRead else {
            throw AppError.photoLibraryAccessDenied
        }
        try Task.checkCancellation()

        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil)
        guard let asset = fetch.firstObject else {
            throw AppError.originalUnavailable
        }

        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.version = .current
        options.isNetworkAccessAllowed = true

        let gate = PhotoRequestGate<Data>()
        let data: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard gate.install(continuation) else { return }

                let requestID = imageManager.requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
                    if let cancelled = info?[PHImageCancelledKey] as? Bool, cancelled {
                        gate.fail(CancellationError())
                        return
                    }
                    if let error = info?[PHImageErrorKey] as? Error {
                        gate.fail(error)
                        return
                    }
                    guard let data else {
                        gate.fail(AppError.originalUnavailable)
                        return
                    }
                    gate.succeed(data)
                }

                if gate.setRequestID(requestID) {
                    imageManager.cancelImageRequest(requestID)
                }
            }
        } onCancel: {
            if let requestID = gate.cancel() {
                self.imageManager.cancelImageRequest(requestID)
            }
        }

        try Task.checkCancellation()
        return data
    }

    private static func map(_ status: PHAuthorizationStatus) -> PhotoAuthorization {
        switch status {
        case .authorized: return .authorized
        case .limited: return .limited
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }

    private static func encodeJPEG(_ image: CGImage, quality: Double) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw AppError.thumbnailEncodingFailed
        }

        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw AppError.thumbnailEncodingFailed
        }
        return output as Data
    }
}
