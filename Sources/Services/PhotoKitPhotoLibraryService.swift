import Foundation
import ImageIO
import Photos
import UIKit
import UniformTypeIdentifiers

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

        let image: UIImage = try await withCheckedThrowingContinuation { continuation in
            var finished = false
            imageManager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                guard !finished else { return }

                if let cancelled = info?[PHImageCancelledKey] as? Bool, cancelled {
                    finished = true
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if let error = info?[PHImageErrorKey] as? Error {
                    finished = true
                    continuation.resume(throwing: error)
                    return
                }
                if let degraded = info?[PHImageResultIsDegradedKey] as? Bool, degraded {
                    return
                }
                guard let image else {
                    finished = true
                    continuation.resume(throwing: AppError.originalUnavailable)
                    return
                }
                finished = true
                continuation.resume(returning: image)
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

        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil)
        guard let asset = fetch.firstObject else {
            throw AppError.originalUnavailable
        }

        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.version = .current
        options.isNetworkAccessAllowed = true

        return try await withCheckedThrowingContinuation { continuation in
            imageManager.requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
                if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let data else {
                    continuation.resume(throwing: AppError.originalUnavailable)
                    return
                }
                continuation.resume(returning: data)
            }
        }
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
