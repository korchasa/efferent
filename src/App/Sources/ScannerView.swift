import AVFoundation
import SwiftUI

/// The whole of setting this app up: point it at the code the reader shows.
///
/// There is nothing secret in that code — an address and a public key — so it
/// can be photographed off a screen without a second thought. That is the reason
/// pairing is a scan and not a careful transfer of a password.
struct ScannerView: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan)
    }

    func makeUIViewController(context: Context) -> ScannerController {
        ScannerController(coordinator: context.coordinator)
    }

    func updateUIViewController(_: ScannerController, context _: Context) {}

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        private let onScan: (String) -> Void
        private var alreadyScanned = false

        init(onScan: @escaping (String) -> Void) {
            self.onScan = onScan
        }

        func metadataOutput(
            _: AVCaptureMetadataOutput,
            didOutput objects: [AVMetadataObject],
            from _: AVCaptureConnection
        ) {
            // The camera fires many times a second over the same code. Without
            // this latch the pairing screen would try to pair dozens of times.
            guard !alreadyScanned else { return }
            guard let code = objects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first,
                  let value = code.stringValue
            else { return }

            alreadyScanned = true
            DispatchQueue.main.async { self.onScan(value) }
        }
    }
}

final class ScannerController: UIViewController {
    private let session = AVCaptureSession()
    private let coordinator: ScannerView.Coordinator
    private var preview: AVCaptureVideoPreviewLayer?

    init(coordinator: ScannerView.Coordinator) {
        self.coordinator = coordinator
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("ScannerController is created in code only")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else { return }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(coordinator, queue: .main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        preview = layer
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Starting the session blocks for a moment; keeping it off the main
        // thread stops the sheet from appearing frozen.
        guard !session.isRunning else { return }
        Task.detached { [session] in session.startRunning() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning {
            session.stopRunning()
        }
    }
}
