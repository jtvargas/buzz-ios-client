import AVFoundation
import SwiftUI

/// A live QR-code camera scanner. Device-only — on the Simulator (and wherever the
/// camera is denied) it renders nothing useful, which is why ``PairingFlowView``
/// always pairs it with a paste-the-link fallback.
struct QRScannerView: UIViewControllerRepresentable {
    /// Called once with the first decoded QR string.
    let onScan: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan)
    }

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_: ScannerViewController, context _: Context) {}

    /// Debounces to a single scan callback — a metadata output fires repeatedly.
    final class Coordinator: ScannerDelegate {
        private let onScan: (String) -> Void
        private var didScan = false

        init(onScan: @escaping (String) -> Void) {
            self.onScan = onScan
        }

        func scanner(didScan code: String) {
            guard !didScan else { return }
            didScan = true
            onScan(code)
        }
    }

    /// Requests camera access, returning whether it is granted. Safe to call when
    /// already authorised (returns immediately).
    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        default:
            return false
        }
    }
}

/// The delegate the view controller reports scans through, hopping to the main
/// actor at the boundary.
protocol ScannerDelegate: AnyObject {
    func scanner(didScan code: String)
}

/// Owns the `AVCaptureSession` and QR metadata pipeline. The session's start/stop
/// runs off the main thread on a dedicated queue; the metadata callback is pinned
/// to `.main`, so it hops onto the main actor to deliver the scan.
final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    weak var delegate: (any ScannerDelegate)?

    private let sessionQueue = DispatchQueue(label: "chat.buzz.hive.qr-scanner")
    private nonisolated(unsafe) let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
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
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else { return }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        previewLayer = preview
    }

    private func start() {
        sessionQueue.async { [session] in
            guard !session.isRunning else { return }
            session.startRunning()
        }
    }

    private func stop() {
        sessionQueue.async { [session] in
            guard session.isRunning else { return }
            session.stopRunning()
        }
    }

    nonisolated func metadataOutput(
        _: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from _: AVCaptureConnection
    ) {
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let code = object.stringValue
        else { return }
        // The output queue is `.main`, so we are on the main actor already.
        MainActor.assumeIsolated {
            delegate?.scanner(didScan: code)
        }
    }
}
