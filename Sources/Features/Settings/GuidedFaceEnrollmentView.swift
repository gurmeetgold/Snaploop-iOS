import AVFoundation
import CoreImage
import ImageIO
import SwiftUI
import UIKit
import Vision

public struct GuidedEnrollmentFrame {
    public let jpegData: Data
    public let pose: FaceTemplate.Pose
    public let quality: Double
}

enum GuidedEnrollmentStep: Int, CaseIterable, Identifiable {
    case front
    case left
    case right
    case tilt
    case finishFront

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .front: return "Front"
        case .left: return "Left"
        case .right: return "Right"
        case .tilt: return "Tilt Down"
        case .finishFront: return "Finish"
        }
    }

    var shortInstruction: String {
        switch self {
        case .front:
            return "Look straight at the camera"
        case .left:
            return "Turn your face LEFT"
        case .right:
            return "Turn your face RIGHT"
        case .tilt:
            return "Tilt slightly DOWN"
        case .finishFront:
            return "Look straight again"
        }
    }

    var symbol: String {
        switch self {
        case .front: return "person.crop.circle"
        case .left: return "arrow.left"
        case .right: return "arrow.right"
        case .tilt: return "arrow.down"
        case .finishFront: return "checkmark"
        }
    }

    var templatePose: FaceTemplate.Pose {
        switch self {
        case .front: return .center
        case .left: return .sideA
        case .right: return .sideB
        case .tilt: return .tilted
        case .finishFront: return .alternate
        }
    }
}

final class GuidedFaceEnrollmentController:
    NSObject,
    ObservableObject,
    AVCaptureVideoDataOutputSampleBufferDelegate {

    @Published var currentStep: GuidedEnrollmentStep = .front
    @Published var completedSteps: Set<GuidedEnrollmentStep> = []
    @Published var instruction = "Center your face inside the oval"
    @Published var detail = "Move a little closer if needed"
    @Published var progress: Double = 0
    @Published var errorMessage: String?
    @Published var isComplete = false
    @Published var faceIsDetected = false
    @Published var faceIsLargeEnough = false
    @Published var qualityIsGood = false

    let session = AVCaptureSession()

    private let queue = DispatchQueue(
        label: "com.snaploop.guided-face-enrollment"
    )
    private let visionQueue = DispatchQueue(
        label: "com.snaploop.guided-face-vision"
    )
    private let ciContext = CIContext()

    private var configured = false
    private var frameCounter = 0
    private var lastCaptureAt = Date.distantPast
    private var captured: [GuidedEnrollmentStep: GuidedEnrollmentFrame] = [:]

    var onCompleted: (([GuidedEnrollmentFrame]) -> Void)?

    func start() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)

        switch status {
        case .authorized:
            configureAndStart()

        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }

                if granted {
                    self.configureAndStart()
                } else {
                    DispatchQueue.main.async {
                        self.errorMessage =
                            "Camera access is required for guided Face Setup."
                    }
                }
            }

        default:
            errorMessage =
                "Camera access is required for guided Face Setup."
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.session.stopRunning()
        }
    }

    private func configureAndStart() {
        queue.async { [weak self] in
            guard let self else { return }

            if !configured {
                do {
                    try configureSession()
                    configured = true
                } catch {
                    DispatchQueue.main.async {
                        self.errorMessage =
                            (error as NSError).localizedDescription
                    }
                    return
                }
            }

            session.startRunning()
        }
    }

    private func configureSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .high

        guard let camera = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .front
        ) else {
            throw NSError(
                domain: "SnapLoop.FaceEnrollment",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Front camera is unavailable."
                ]
            )
        }

        let input = try AVCaptureDeviceInput(device: camera)

        guard session.canAddInput(input) else {
            throw NSError(
                domain: "SnapLoop.FaceEnrollment",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Could not open the front camera."
                ]
            )
        }

        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_32BGRA
        ]

        output.setSampleBufferDelegate(self, queue: visionQueue)

        guard session.canAddOutput(output) else {
            throw NSError(
                domain: "SnapLoop.FaceEnrollment",
                code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Could not analyze camera frames."
                ]
            )
        }

        session.addOutput(output)

        if let connection = output.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }

            if connection.isVideoMirroringSupported {
                connection.isVideoMirrored = true
            }
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard !isComplete else { return }

        frameCounter += 1
        guard frameCounter % 3 == 0 else { return }

        guard let pixelBuffer =
            CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        autoreleasepool {
            analyze(pixelBuffer)
        }
    }

    private func analyze(_ pixelBuffer: CVPixelBuffer) {
        let rectangles = VNDetectFaceRectanglesRequest()
        let quality = VNDetectFaceCaptureQualityRequest()

        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: .up,
            options: [:]
        )

        do {
            try handler.perform([rectangles, quality])
        } catch {
            return
        }

        let faces = rectangles.results ?? []

        guard faces.count == 1, let face = faces.first else {
            publishState(
                detected: false,
                largeEnough: false,
                goodQuality: false,
                instruction: faces.isEmpty
                    ? "Place your face inside the oval"
                    : "Only one face should be visible",
                detail: "Keep the phone steady"
            )
            return
        }

        let qualityFace = quality.results?.first
        let captureQuality = Double(
            qualityFace?.faceCaptureQuality ?? 0
        )

        let faceArea =
            face.boundingBox.width * face.boundingBox.height

        let largeEnough = faceArea >= 0.12
        let goodQuality = captureQuality >= 0.35

        guard largeEnough else {
            publishState(
                detected: true,
                largeEnough: false,
                goodQuality: goodQuality,
                instruction: "Move a little closer",
                detail: "Keep your whole face inside the oval"
            )
            return
        }

        guard goodQuality else {
            publishState(
                detected: true,
                largeEnough: true,
                goodQuality: false,
                instruction: "Hold still in better light",
                detail: "Avoid strong backlight or motion blur"
            )
            return
        }

        let yawDegrees =
            (face.yaw?.doubleValue ?? 0) * 180 / .pi
        let pitchDegrees =
            (face.pitch?.doubleValue ?? 0) * 180 / .pi

        let step = currentStep

        guard qualifies(
            step: step,
            yaw: yawDegrees,
            pitch: pitchDegrees
        ) else {
            publishState(
                detected: true,
                largeEnough: true,
                goodQuality: true,
                instruction: step.shortInstruction,
                detail: liveDirectionHint(
                    for: step,
                    yaw: yawDegrees,
                    pitch: pitchDegrees
                )
            )
            return
        }

        guard Date().timeIntervalSince(lastCaptureAt) >= 0.7 else {
            return
        }

        guard let jpeg = makeJPEG(pixelBuffer) else {
            return
        }

        lastCaptureAt = Date()

        captured[step] = GuidedEnrollmentFrame(
            jpegData: jpeg,
            pose: step.templatePose,
            quality: captureQuality
        )

        DispatchQueue.main.async {
            self.completedSteps.insert(step)
        }

        advance()
    }

    private func qualifies(
        step: GuidedEnrollmentStep,
        yaw: Double,
        pitch: Double
    ) -> Bool {
        switch step {
        case .front:
            return abs(yaw) <= 8 && abs(pitch) <= 10

        case .left:
            return yaw <= -16 && yaw >= -38

        case .right:
            return yaw >= 16 && yaw <= 38

        case .tilt:
            // Vision's positive pitch on the mirrored front-camera stream corresponds
            // to lowering the chin. Keep the proven numeric threshold and fix the UX
            // direction so the instruction matches what the detector actually accepts.
            return pitch >= 9 && pitch <= 28 && abs(yaw) <= 18

        case .finishFront:
            return abs(yaw) <= 10 && abs(pitch) <= 12
        }
    }

    private func liveDirectionHint(
        for step: GuidedEnrollmentStep,
        yaw: Double,
        pitch: Double
    ) -> String {
        switch step {
        case .front, .finishFront:
            if yaw < -8 { return "Turn slightly RIGHT toward center" }
            if yaw > 8 { return "Turn slightly LEFT toward center" }
            if pitch < -10 { return "Raise your chin slightly" }
            if pitch > 10 { return "Lower your chin slightly" }
            return "Hold still"

        case .left:
            return yaw > -16
                ? "Keep turning LEFT"
                : "Come slightly back toward center"

        case .right:
            return yaw < 16
                ? "Keep turning RIGHT"
                : "Come slightly back toward center"

        case .tilt:
            return pitch < 9
                ? "Lower your chin a little"
                : "Raise your chin slightly"
        }
    }

    private func advance() {
        let nextRaw = currentStep.rawValue + 1

        if let next = GuidedEnrollmentStep(rawValue: nextRaw) {
            DispatchQueue.main.async {
                self.currentStep = next
                self.progress =
                    Double(self.completedSteps.count)
                    / Double(GuidedEnrollmentStep.allCases.count)
                self.instruction = next.shortInstruction
                self.detail = "Follow the arrow and hold briefly"
            }
        } else {
            finish()
        }
    }

    private func makeJPEG(_ buffer: CVPixelBuffer) -> Data? {
        // The AVCapture connection already rotates/mirrors the delivered video.
        // Applying an additional CIImage orientation here caused the saved face
        // reference to appear sideways on real iPhones.
        let image = CIImage(cvPixelBuffer: buffer)

        guard let cgImage = ciContext.createCGImage(
            image,
            from: image.extent
        ) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
            .jpegData(compressionQuality: 0.93)
    }

    private func finish() {
        guard !isComplete else { return }

        let frames = GuidedEnrollmentStep.allCases.compactMap {
            captured[$0]
        }

        DispatchQueue.main.async {
            self.isComplete = true
            self.progress = 1
            self.instruction = "Face scan complete"
            self.detail = "\(frames.count) useful angles captured"
            self.onCompleted?(frames)
        }

        stop()
    }

    private func publishState(
        detected: Bool,
        largeEnough: Bool,
        goodQuality: Bool,
        instruction: String,
        detail: String
    ) {
        DispatchQueue.main.async {
            self.faceIsDetected = detected
            self.faceIsLargeEnough = largeEnough
            self.qualityIsGood = goodQuality
            self.instruction = instruction
            self.detail = detail
        }
    }
}

final class CameraPreviewView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}

struct GuidedCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(
        _ uiView: CameraPreviewView,
        context: Context
    ) {}
}

struct GuidedFaceEnrollmentView: View {
    @Environment(\.dismiss) private var dismiss

    @StateObject private var controller =
        GuidedFaceEnrollmentController()

    let onComplete: ([GuidedEnrollmentFrame]) -> Void

    var body: some View {
        ZStack {
            GuidedCameraPreview(session: controller.session)
                .ignoresSafeArea()

            Color.black.opacity(0.16)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar

                stepRail
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                Spacer()

                faceGuide

                Spacer()

                instructionCard
                    .padding()
            }
        }
        .onAppear {
            controller.onCompleted = { frames in
                onComplete(frames)
                dismiss()
            }
            controller.start()
        }
        .onDisappear {
            controller.stop()
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                controller.stop()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.black.opacity(0.45), in: Circle())
            }

            Spacer()

            Text("Face Scan")
                .font(.headline)
                .foregroundStyle(.white)

            Spacer()

            Color.clear
                .frame(width: 44, height: 44)
        }
        .padding()
    }

    private var stepRail: some View {
        HStack(spacing: 6) {
            ForEach(GuidedEnrollmentStep.allCases) { step in
                VStack(spacing: 5) {
                    ZStack {
                        Circle()
                            .fill(
                                controller.completedSteps.contains(step)
                                    ? Color.green
                                    : controller.currentStep == step
                                        ? Color.white
                                        : Color.black.opacity(0.35)
                            )
                            .frame(width: 34, height: 34)

                        Image(
                            systemName:
                                controller.completedSteps.contains(step)
                                ? "checkmark"
                                : step.symbol
                        )
                        .font(.caption.bold())
                        .foregroundStyle(
                            controller.completedSteps.contains(step)
                                ? .white
                                : controller.currentStep == step
                                    ? .black
                                    : .white
                        )
                    }

                    Text(step.title)
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(10)
        .background(.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 18))
    }

    private var faceGuide: some View {
        ZStack {
            Ellipse()
                .stroke(
                    controller.faceIsDetected
                        ? (controller.faceIsLargeEnough && controller.qualityIsGood
                            ? Color.green
                            : Color.yellow)
                        : Color.white,
                    style: StrokeStyle(lineWidth: 4, dash: [10, 7])
                )
                .frame(width: 270, height: 350)

            Image(systemName: controller.currentStep.symbol)
                .font(.system(size: 58, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .offset(y: 235)
        }
    }

    private var instructionCard: some View {
        VStack(spacing: 10) {
            Text(controller.instruction)
                .font(.title3.bold())
                .multilineTextAlignment(.center)

            Text(controller.detail)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.86))

            ProgressView(value: controller.progress)
                .tint(.green)

            if let error = controller.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .foregroundStyle(.white)
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 22))
    }
}
