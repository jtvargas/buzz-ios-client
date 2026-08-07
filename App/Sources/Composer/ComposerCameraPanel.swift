import AVFoundation
import SwiftUI

/// One still photo produced by the inline camera, handed to the existing attachment pipeline.
struct ComposerCameraCapture: ComposerPickedItem {
    let data: Data

    var suggestedFilename: String? { nil }

    func loadData() async throws -> Data {
        guard !data.isEmpty else { throw ComposerAttachmentError.emptyPick }
        return data
    }
}

/// The live, back-camera-only panel docked immediately above the message composer.
struct ComposerCameraPanel: View {
    private enum Access: Equatable {
        case requesting
        case granted
        case unavailable
    }

    let canCapture: Bool
    let onCapture: @MainActor @Sendable (ComposerCameraCapture) -> Void
    let atCapacity: @MainActor @Sendable () -> Void
    let close: @MainActor @Sendable () -> Void

    @State private var access = Access.requesting
    @State private var isSessionAvailable: Bool?
    @State private var captureRequest = 0

    /// The panel shares the composer's measured 12-point side inset. At 440 points this
    /// leaves the approved 416-point width.
    static let horizontalInset: CGFloat = 12
    static let height: CGFloat = 308
    static let cornerRadius: CGFloat = 15
    static let shutterDiameter: CGFloat = 64
    static let shutterStroke: CGFloat = 3
    static let shutterGap: CGFloat = 4
    static var shutterDiscDiameter: CGFloat {
        shutterDiameter - 2 * (shutterStroke + shutterGap)
    }
    static let shutterBottomInset: CGFloat = 12
    static let closeGlyph: CGFloat = 10
    static let closeTarget: CGFloat = 44
    static let closeTrailingInset: CGFloat = 4

    var body: some View {
        ZStack {
            Color.black
            cameraContent
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .clipShape(.rect(cornerRadius: Self.cornerRadius))
        .overlay(alignment: .topTrailing) { closeButton }
        .overlay(alignment: .bottom) {
            if access == .granted, isSessionAvailable == true {
                shutterButton
                    .padding(.bottom, Self.shutterBottomInset)
            }
        }
        .task { await requestAccess() }
    }

    @ViewBuilder
    private var cameraContent: some View {
        switch access {
        case .requesting:
            ProgressView()
                .tint(.white)
                .accessibilityLabel("Opening camera")
        case .unavailable:
            unavailable
        case .granted:
            ComposerCameraPreview(
                captureRequest: captureRequest,
                onCapture: { onCapture(ComposerCameraCapture(data: $0)) },
                onAvailabilityChange: { isSessionAvailable = $0 }
            )
            .overlay {
                if isSessionAvailable == nil {
                    ProgressView()
                        .tint(.white)
                        .accessibilityLabel("Opening camera")
                } else if isSessionAvailable == false {
                    unavailable
                }
            }
        }
    }

    private var unavailable: some View {
        VStack(spacing: 8) {
            Image(systemName: "camera.fill")
                .font(.hiveSymbol(.title2))
                .accessibilityHidden(true)
            Text("Camera unavailable")
                .font(.hive(.headline, weight: .semibold))
            Text("Camera access is unavailable on this device.")
                .font(.hive(.footnote))
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
        .padding()
    }

    private var shutterButton: some View {
        Button(action: takePhoto) {
            ZStack {
                Circle()
                    .strokeBorder(.white, lineWidth: Self.shutterStroke)
                    .frame(width: Self.shutterDiameter, height: Self.shutterDiameter)
                Circle()
                    .fill(.white)
                    .frame(width: Self.shutterDiscDiameter, height: Self.shutterDiscDiameter)
            }
            .frame(width: Self.shutterDiameter, height: Self.shutterDiameter)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Take photo")
    }

    private var closeButton: some View {
        Button(action: close) {
            Image(systemName: "xmark")
                .font(.system(size: Self.closeGlyph, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: Self.closeTarget, height: Self.closeTarget)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.trailing, Self.closeTrailingInset)
        .accessibilityLabel("Close camera")
    }

    private func takePhoto() {
        guard canCapture else {
            atCapacity()
            return
        }
        captureRequest &+= 1
    }

    private func requestAccess() async {
        let granted = await QRScannerView.requestAccess()
        guard !Task.isCancelled else { return }
        access = granted ? .granted : .unavailable
    }
}

/// SwiftUI's edge around the UIKit controller that owns the capture session and preview.
private struct ComposerCameraPreview: UIViewControllerRepresentable {
    let captureRequest: Int
    let onCapture: @MainActor @Sendable (Data) -> Void
    let onAvailabilityChange: @MainActor @Sendable (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onAvailabilityChange: onAvailabilityChange)
    }

    func makeUIViewController(context: Context) -> ComposerCameraViewController {
        let controller = ComposerCameraViewController(
            availabilityChanged: context.coordinator.reportAvailability
        )
        return controller
    }

    func updateUIViewController(
        _ controller: ComposerCameraViewController,
        context: Context
    ) {
        guard context.coordinator.captureRequest != captureRequest else { return }
        context.coordinator.captureRequest = captureRequest
        controller.capture(using: context.coordinator)
    }

    final class Coordinator: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
        var captureRequest = 0

        private let onCapture: @MainActor @Sendable (Data) -> Void
        private let onAvailabilityChange: @MainActor @Sendable (Bool) -> Void

        init(
            onCapture: @escaping @MainActor @Sendable (Data) -> Void,
            onAvailabilityChange: @escaping @MainActor @Sendable (Bool) -> Void
        ) {
            self.onCapture = onCapture
            self.onAvailabilityChange = onAvailabilityChange
        }

        nonisolated func reportAvailability(_ isAvailable: Bool) {
            Task { @MainActor [onAvailabilityChange] in
                onAvailabilityChange(isAvailable)
            }
        }

        nonisolated func photoOutput(
            _: AVCapturePhotoOutput,
            didFinishProcessingPhoto photo: AVCapturePhoto,
            error: Error?
        ) {
            guard error == nil, let data = photo.fileDataRepresentation() else { return }
            Task { @MainActor [onCapture] in
                onCapture(data)
            }
        }
    }

}

/// Owns the back-camera session. All session mutations run on `sessionQueue`; UIKit and the
/// preview layer stay on the main actor.
private final class ComposerCameraViewController: UIViewController {
    private let sessionQueue = DispatchQueue(label: "chat.buzz.hive.composer-camera")
    private nonisolated(unsafe) let session = AVCaptureSession()
    private nonisolated(unsafe) let photoOutput = AVCapturePhotoOutput()
    private let availabilityChanged: @Sendable (Bool) -> Void
    private var previewLayer: AVCaptureVideoPreviewLayer?

    init(availabilityChanged: @escaping @Sendable (Bool) -> Void) {
        self.availabilityChanged = availabilityChanged
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        previewLayer = preview

        configureSession()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        start()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stop()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
        if let connection = previewLayer?.connection,
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
    }

    func capture(using delegate: ComposerCameraPreview.Coordinator) {
        let session = session
        let output = photoOutput
        sessionQueue.async {
            guard session.isRunning else { return }
            if let connection = output.connection(with: .video),
               connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
            output.capturePhoto(with: AVCapturePhotoSettings(), delegate: delegate)
        }
    }

    private func configureSession() {
        let session = session
        let output = photoOutput
        let availabilityChanged = availabilityChanged
        sessionQueue.async {
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            session.sessionPreset = .photo

            guard let device = AVCaptureDevice.default(
                .builtInWideAngleCamera,
                for: .video,
                position: .back
            ), let input = try? AVCaptureDeviceInput(device: device),
                session.canAddInput(input), session.canAddOutput(output)
            else {
                availabilityChanged(false)
                return
            }
            session.addInput(input)
            session.addOutput(output)
            availabilityChanged(true)
        }
    }

    private func start() {
        let session = session
        sessionQueue.async {
            guard !session.inputs.isEmpty, !session.isRunning else { return }
            session.startRunning()
        }
    }

    private func stop() {
        let session = session
        sessionQueue.async {
            guard session.isRunning else { return }
            session.stopRunning()
        }
    }
}
