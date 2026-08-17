import SwiftUI
import UIKit

struct ProfileImagePicker:
    UIViewControllerRepresentable {

    enum Source {
        case camera
        case photoLibrary
    }

    let source: Source
    let onImage: (UIImage) -> Void

    final class Coordinator:
        NSObject,
        UINavigationControllerDelegate,
        UIImagePickerControllerDelegate {

        let parent:
            ProfileImagePicker

        init(
            parent:
                ProfileImagePicker
        ) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker:
                UIImagePickerController,
            didFinishPickingMediaWithInfo
                info: [
                    UIImagePickerController
                        .InfoKey: Any
                ]
        ) {
            let image =
                (info[.editedImage]
                    as? UIImage)
                ?? (info[.originalImage]
                    as? UIImage)

            if let image {
                parent.onImage(image)
            }

            picker.dismiss(
                animated: true
            )
        }

        func imagePickerControllerDidCancel(
            _ picker:
                UIImagePickerController
        ) {
            picker.dismiss(
                animated: true
            )
        }
    }

    func makeCoordinator()
        -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(
        context: Context
    ) -> UIImagePickerController {
        let picker =
            UIImagePickerController()

        picker.delegate =
            context.coordinator

        switch source {
        case .camera:
            picker.sourceType =
                .camera
            picker.cameraDevice =
                .front
            picker.cameraCaptureMode =
                .photo

        case .photoLibrary:
            picker.sourceType =
                .photoLibrary
        }

        picker.allowsEditing = true

        return picker
    }

    func updateUIViewController(
        _ uiViewController:
            UIImagePickerController,
        context: Context
    ) {}
}
