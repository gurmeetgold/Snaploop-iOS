import AVFoundation
import SwiftUI
import UIKit

struct QRCodeScannerSheet: View {
    let onScanned: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var cameraAllowed: Bool?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if cameraAllowed == true {
                    QRCodeCameraView { value in
                        onScanned(value)
                        dismiss()
                    }
                    .ignoresSafeArea()

                    VStack {
                        Spacer()
                        Text("Point your camera at a SnapLoop Event QR code")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 12)
                            .background(.black.opacity(0.58), in: Capsule())
                            .padding(.bottom, 36)
                    }
                } else if cameraAllowed == false {
                    ContentUnavailableViewCompat(
                        title: "Camera Access Needed",
                        message: "Allow camera access in Settings to scan an Event QR code.",
                        systemImage: "camera.fill"
                    )
                    .foregroundStyle(.white)
                } else {
                    ProgressView()
                        .tint(.white)
                        .controlSize(.large)
                }
            }
            .navigationTitle("Scan Event QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.white)
                }
                if cameraAllowed == false {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Settings") { openSettings() }
                            .foregroundStyle(.white)
                    }
                }
            }
            .task { await resolveCameraPermission() }
        }
    }

    @MainActor
    private func resolveCameraPermission() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            cameraAllowed = true
        case .notDetermined:
            cameraAllowed = await AVCaptureDevice.requestAccess(for: .video)
        case .denied, .restricted:
            cameraAllowed = false
        @unknown default:
            cameraAllowed = false
        }
    }

    @MainActor
    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

private struct QRCodeCameraView: UIViewControllerRepresentable {
    let onScanned: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScanned: onScanned)
    }

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let controller = QRScannerViewController()
        controller.onMetadata = context.coordinator.handle
        return controller
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: QRScannerViewController, coordinator: Coordinator) {
        uiViewController.stopSession()
    }

    final class Coordinator {
        private let onScanned: (String) -> Void
        private var delivered = false

        init(onScanned: @escaping (String) -> Void) {
            self.onScanned = onScanned
        }

        func handle(_ value: String) {
            guard !delivered else { return }
            delivered = true
            onScanned(value)
        }
    }
}

private final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onMetadata: ((String) -> Void)?

    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var configured = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureIfNeeded()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startSession()
    }

    override func viewWillDisappear(_ animated: Bool) {
        stopSession()
        super.viewWillDisappear(animated)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    private func configureIfNeeded() {
        guard !configured else { return }
        configured = true

        guard
            let camera = AVCaptureDevice.default(for: .video),
            let input = try? AVCaptureDeviceInput(device: camera),
            session.canAddInput(input)
        else { return }

        session.beginConfiguration()
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        session.commitConfiguration()

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.insertSublayer(preview, at: 0)
        previewLayer = preview
    }

    func startSession() {
        guard configured, !session.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
        }
    }

    func stopSession() {
        guard session.isRunning else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.session.stopRunning()
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard
            let readable = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
            readable.type == .qr,
            let value = readable.stringValue,
            !value.isEmpty
        else { return }

        onMetadata?(value)
    }
}
