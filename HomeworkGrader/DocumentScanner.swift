import SwiftUI
import UIKit
import VisionKit
import AVFoundation

enum ScanCaptureSource: String, Identifiable {
    case documentScanner = "Document Scanner"
    case camera = "Camera"

    var id: String { rawValue }

    var buttonTitle: String { rawValue }

    var systemImage: String {
        switch self {
        case .documentScanner:
            return "doc.viewfinder"
        case .camera:
            return "camera"
        }
    }
}

struct DocumentScannerView: UIViewControllerRepresentable {
    let onComplete: ([UIImage]) -> Void
    let onCancel: () -> Void
    let onError: (Error) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: DocumentScannerView

        init(parent: DocumentScannerView) {
            self.parent = parent
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.onCancel()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            parent.onError(error)
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            let images = (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }
            parent.onComplete(images)
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct CameraCaptureView: UIViewControllerRepresentable {
    let onComplete: ([UIImage]) -> Void
    let onCancel: () -> Void
    let onError: (Error) -> Void

    func makeUIViewController(context: Context) -> CameraCaptureViewController {
        let controller = CameraCaptureViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: CameraCaptureViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, CameraCaptureViewControllerDelegate {
        let parent: CameraCaptureView

        init(parent: CameraCaptureView) {
            self.parent = parent
        }

        func cameraCaptureViewControllerDidCancel(_ controller: CameraCaptureViewController) {
            parent.onCancel()
        }

        func cameraCaptureViewController(_ controller: CameraCaptureViewController, didFailWithError error: Error) {
            parent.onError(error)
        }

        func cameraCaptureViewController(_ controller: CameraCaptureViewController, didFinishWith images: [UIImage]) {
            parent.onComplete(images)
        }
    }
}

protocol CameraCaptureViewControllerDelegate: AnyObject {
    func cameraCaptureViewControllerDidCancel(_ controller: CameraCaptureViewController)
    func cameraCaptureViewController(_ controller: CameraCaptureViewController, didFailWithError error: Error)
    func cameraCaptureViewController(_ controller: CameraCaptureViewController, didFinishWith images: [UIImage])
}

final class CameraCaptureViewController: UIViewController {
    weak var delegate: CameraCaptureViewControllerDelegate?

    static var isCaptureAvailable: Bool {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil
    }

    private let captureSession = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "HomeworkGrader.CameraCapture.Session")
    private let previewView = CameraPreviewView()
    private let overlayView = UIView()
    private let countLabel = UILabel()
    private let hintLabel = UILabel()
    private let captureButton = UIButton(type: .system)
    private let doneButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private var capturedImages: [UIImage] = [] {
        didSet {
            updateCountLabel()
            doneButton.isEnabled = !capturedImages.isEmpty
            doneButton.alpha = capturedImages.isEmpty ? 0.5 : 1.0
        }
    }
    private var isConfigured = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureUI()
        checkAuthorizationAndConfigureSession()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        sessionQueue.async {
            if self.isConfigured, !self.captureSession.isRunning {
                self.captureSession.startRunning()
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sessionQueue.async {
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
        }
    }

    private func configureUI() {
        previewView.previewLayer.session = captureSession
        previewView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(previewView)

        overlayView.translatesAutoresizingMaskIntoConstraints = false
        overlayView.backgroundColor = .clear
        view.addSubview(overlayView)

        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.textColor = .white
        countLabel.font = .preferredFont(forTextStyle: .headline)
        countLabel.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        countLabel.layer.cornerRadius = 14
        countLabel.layer.masksToBounds = true
        countLabel.textAlignment = .center
        overlayView.addSubview(countLabel)

        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.textColor = UIColor.white.withAlphaComponent(0.9)
        hintLabel.font = .preferredFont(forTextStyle: .footnote)
        hintLabel.numberOfLines = 0
        hintLabel.textAlignment = .center
        hintLabel.text = "Tap capture for each page. You can keep taking photos, then tap Done when the stack is complete."
        overlayView.addSubview(hintLabel)

        captureButton.translatesAutoresizingMaskIntoConstraints = false
        captureButton.tintColor = .white
        captureButton.backgroundColor = UIColor.white.withAlphaComponent(0.18)
        captureButton.layer.cornerRadius = 36
        captureButton.layer.borderWidth = 4
        captureButton.layer.borderColor = UIColor.white.withAlphaComponent(0.9).cgColor
        captureButton.setImage(UIImage(systemName: "circle.fill"), for: .normal)
        captureButton.imageView?.contentMode = .scaleAspectFit
        captureButton.addTarget(self, action: #selector(capturePhoto), for: .touchUpInside)
        overlayView.addSubview(captureButton)

        doneButton.translatesAutoresizingMaskIntoConstraints = false
        doneButton.setTitle("Done", for: .normal)
        doneButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        doneButton.tintColor = .white
        doneButton.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.85)
        doneButton.layer.cornerRadius = 14
        doneButton.addTarget(self, action: #selector(finishCapture), for: .touchUpInside)
        overlayView.addSubview(doneButton)

        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        cancelButton.tintColor = .white
        cancelButton.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        cancelButton.layer.cornerRadius = 14
        cancelButton.addTarget(self, action: #selector(cancelCapture), for: .touchUpInside)
        overlayView.addSubview(cancelButton)

        NSLayoutConstraint.activate([
            previewView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            previewView.topAnchor.constraint(equalTo: view.topAnchor),
            previewView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            overlayView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            overlayView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            overlayView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            overlayView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            cancelButton.leadingAnchor.constraint(equalTo: overlayView.leadingAnchor, constant: 20),
            cancelButton.topAnchor.constraint(equalTo: overlayView.topAnchor, constant: 16),

            countLabel.centerXAnchor.constraint(equalTo: overlayView.centerXAnchor),
            countLabel.topAnchor.constraint(equalTo: overlayView.topAnchor, constant: 16),
            countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            countLabel.heightAnchor.constraint(equalToConstant: 32),

            doneButton.trailingAnchor.constraint(equalTo: overlayView.trailingAnchor, constant: -20),
            doneButton.topAnchor.constraint(equalTo: overlayView.topAnchor, constant: 16),

            hintLabel.leadingAnchor.constraint(equalTo: overlayView.leadingAnchor, constant: 24),
            hintLabel.trailingAnchor.constraint(equalTo: overlayView.trailingAnchor, constant: -24),
            hintLabel.bottomAnchor.constraint(equalTo: captureButton.topAnchor, constant: -24),

            captureButton.centerXAnchor.constraint(equalTo: overlayView.centerXAnchor),
            captureButton.bottomAnchor.constraint(equalTo: overlayView.bottomAnchor, constant: -28),
            captureButton.widthAnchor.constraint(equalToConstant: 72),
            captureButton.heightAnchor.constraint(equalToConstant: 72),
        ])

        doneButton.isEnabled = false
        doneButton.alpha = 0.5
        updateCountLabel()
    }

    private func checkAuthorizationAndConfigureSession() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSessionIfNeeded()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                DispatchQueue.main.async {
                    if granted {
                        self.configureSessionIfNeeded()
                    } else {
                        self.delegate?.cameraCaptureViewController(
                            self,
                            didFailWithError: CameraCaptureError.cameraAccessDenied
                        )
                    }
                }
            }
        default:
            delegate?.cameraCaptureViewController(self, didFailWithError: CameraCaptureError.cameraAccessDenied)
        }
    }

    private func configureSessionIfNeeded() {
        guard !isConfigured else { return }

        sessionQueue.async {
            do {
                self.captureSession.beginConfiguration()
                self.captureSession.sessionPreset = .photo

                guard
                    let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                else {
                    throw CameraCaptureError.cameraUnavailable
                }

                let input = try AVCaptureDeviceInput(device: camera)
                if self.captureSession.canAddInput(input) {
                    self.captureSession.addInput(input)
                } else {
                    throw CameraCaptureError.cameraUnavailable
                }

                if self.captureSession.canAddOutput(self.photoOutput) {
                    self.captureSession.addOutput(self.photoOutput)
                    self.photoOutput.maxPhotoQualityPrioritization = .quality
                } else {
                    throw CameraCaptureError.cameraUnavailable
                }

                self.captureSession.commitConfiguration()
                self.isConfigured = true
                self.captureSession.startRunning()
            } catch {
                self.captureSession.commitConfiguration()
                DispatchQueue.main.async {
                    self.delegate?.cameraCaptureViewController(self, didFailWithError: error)
                }
            }
        }
    }

    private func updateCountLabel() {
        countLabel.text = "Pages: \(capturedImages.count)"
    }

    @objc
    private func capturePhoto() {
        let settings = AVCapturePhotoSettings()
        settings.photoQualityPrioritization = .quality
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    @objc
    private func finishCapture() {
        delegate?.cameraCaptureViewController(self, didFinishWith: capturedImages)
    }

    @objc
    private func cancelCapture() {
        delegate?.cameraCaptureViewControllerDidCancel(self)
    }
}

extension CameraCaptureViewController: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            delegate?.cameraCaptureViewController(self, didFailWithError: error)
            return
        }

        guard
            let data = photo.fileDataRepresentation(),
            let image = UIImage(data: data)
        else {
            delegate?.cameraCaptureViewController(self, didFailWithError: CameraCaptureError.unableToDecodePhoto)
            return
        }

        capturedImages.append(image)
    }
}

private final class CameraPreviewView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        guard let layer = layer as? AVCaptureVideoPreviewLayer else {
            fatalError("CameraPreviewView layer was not AVCaptureVideoPreviewLayer")
        }
        return layer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        previewLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        previewLayer.videoGravity = .resizeAspect
    }
}

enum CameraCaptureError: LocalizedError {
    case cameraUnavailable
    case cameraAccessDenied
    case unableToDecodePhoto

    var errorDescription: String? {
        switch self {
        case .cameraUnavailable:
            return "Camera capture is not available on this device."
        case .cameraAccessDenied:
            return "Camera access is required to take photos."
        case .unableToDecodePhoto:
            return "The captured photo could not be processed."
        }
    }
}
