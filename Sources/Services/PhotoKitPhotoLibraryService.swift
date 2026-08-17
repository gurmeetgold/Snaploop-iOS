import Foundation
import ImageIO
import Photos
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

    public func imageData(for assetId: String, maxPixelSize: Int) async throws -> Data {
        let original = try await originalImageData(for: assetId)
        return try Self.downsampleJPEG(original, maxPixelSize: maxPixelSize)
    }

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

    private static func downsampleJPEG(_ data: Data, maxPixelSize: Int) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw AppError.thumbnailEncodingFailed
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize)
        ]

        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw AppError.thumbnailEncodingFailed
        }

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
            [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary
        )

        guard CGImageDestinationFinalize(destination) else {
            throw AppError.thumbnailEncodingFailed
        }
        return output as Data
    }
}
