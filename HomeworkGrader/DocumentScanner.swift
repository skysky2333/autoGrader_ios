import SwiftUI
import UIKit
import VisionKit
import AVFoundation

enum ScanCaptureStorage {
    static func makeCaptureDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HomeworkGraderCapture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func writeJPEGImage(_ image: UIImage, index: Int, directory: URL) throws -> URL {
        let normalized = normalizedImage(from: image)
        guard let data = normalized.jpegData(compressionQuality: 0.92) else {
            throw ScanCaptureStorageError.unableToPersistCapture
        }

        let fileURL = directory.appendingPathComponent(String(format: "page-%04d.jpg", index + 1))
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    static func writeImageData(_ data: Data, index: Int, directory: URL) throws -> URL {
        let outputData: Data
        if
            let image = UIImage(data: data),
            let jpegData = normalizedImage(from: image).jpegData(compressionQuality: 0.92)
        {
            outputData = jpegData
        } else {
            outputData = data
        }

        let fileURL = directory.appendingPathComponent(String(format: "page-%04d.jpg", index + 1))
        try outputData.write(to: fileURL, options: .atomic)
        return fileURL
    }

    static func removeFiles(at fileURLs: [URL]) {
        let directories = Set(fileURLs.map { $0.deletingLastPathComponent() })
        for fileURL in fileURLs {
            try? FileManager.default.removeItem(at: fileURL)
        }
        for directory in directories {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    static func removeDirectory(_ directory: URL?) {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    private static func normalizedImage(from image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        format.opaque = true

        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }
}

enum ScanCaptureStorageError: LocalizedError {
    case unableToPersistCapture

    var errorDescription: String? {
        switch self {
        case .unableToPersistCapture:
            return "The captured page could not be saved for processing."
        }
    }
}

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
    let onComplete: ([URL]) -> Void
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
            var directory: URL?
            do {
                let captureDirectory = try ScanCaptureStorage.makeCaptureDirectory()
                directory = captureDirectory
                var fileURLs: [URL] = []
                fileURLs.reserveCapacity(scan.pageCount)

                for index in 0..<scan.pageCount {
                    let fileURL = try autoreleasepool {
                        let image = scan.imageOfPage(at: index)
                        return try ScanCaptureStorage.writeJPEGImage(image, index: index, directory: captureDirectory)
                    }
                    fileURLs.append(fileURL)
                }

                parent.onComplete(fileURLs)
            } catch {
                ScanCaptureStorage.removeDirectory(directory)
                parent.onError(error)
            }
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
    let onComplete: ([URL]) -> Void
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

        func cameraCaptureViewController(_ controller: CameraCaptureViewController, didFinishWith fileURLs: [URL]) {
            parent.onComplete(fileURLs)
        }
    }
}

protocol CameraCaptureViewControllerDelegate: AnyObject {
    func cameraCaptureViewControllerDidCancel(_ controller: CameraCaptureViewController)
    func cameraCaptureViewController(_ controller: CameraCaptureViewController, didFailWithError error: Error)
    func cameraCaptureViewController(_ controller: CameraCaptureViewController, didFinishWith fileURLs: [URL])
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
    private let feedbackLabel = UILabel()
    private let previewContainerView = UIView()
    private let previewImageView = UIImageView()
    private let previewPlaceholderImageView = UIImageView()
    private let captureButton = UIButton(type: .system)
    private let captureActivityIndicator = UIActivityIndicatorView(style: .medium)
    private let deleteLastButton = UIButton(type: .system)
    private let doneButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private let flashView = UIView()
    private var captureDirectoryURL: URL?
    private var capturedPageURLs: [URL] = [] {
        didSet {
            updateCountLabel()
            updatePreview()
            doneButton.isEnabled = !capturedPageURLs.isEmpty
            doneButton.alpha = capturedPageURLs.isEmpty ? 0.5 : 1.0
        }
    }
    private var lastPreviewImage: UIImage?
    private var isConfigured = false
    private var isCaptureInProgress = false {
        didSet {
            updateCaptureInteractivity()
        }
    }
    private var feedbackDismissWorkItem: DispatchWorkItem?

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

        flashView.translatesAutoresizingMaskIntoConstraints = false
        flashView.backgroundColor = .white
        flashView.alpha = 0
        view.addSubview(flashView)

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

        feedbackLabel.translatesAutoresizingMaskIntoConstraints = false
        feedbackLabel.textColor = .white
        feedbackLabel.font = .preferredFont(forTextStyle: .subheadline)
        feedbackLabel.textAlignment = .center
        feedbackLabel.numberOfLines = 2
        feedbackLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        feedbackLabel.layer.cornerRadius = 14
        feedbackLabel.layer.masksToBounds = true
        feedbackLabel.alpha = 0
        overlayView.addSubview(feedbackLabel)

        previewContainerView.translatesAutoresizingMaskIntoConstraints = false
        previewContainerView.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        previewContainerView.layer.cornerRadius = 16
        previewContainerView.layer.masksToBounds = true
        previewContainerView.isUserInteractionEnabled = true
        overlayView.addSubview(previewContainerView)

        previewImageView.translatesAutoresizingMaskIntoConstraints = false
        previewImageView.contentMode = .scaleAspectFill
        previewImageView.clipsToBounds = true
        previewContainerView.addSubview(previewImageView)

        previewPlaceholderImageView.translatesAutoresizingMaskIntoConstraints = false
        previewPlaceholderImageView.tintColor = UIColor.white.withAlphaComponent(0.75)
        previewPlaceholderImageView.contentMode = .scaleAspectFit
        previewPlaceholderImageView.image = UIImage(systemName: "photo")
        previewContainerView.addSubview(previewPlaceholderImageView)

        let previewTapGesture = UITapGestureRecognizer(target: self, action: #selector(showLastPhotoPreview))
        previewContainerView.addGestureRecognizer(previewTapGesture)

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

        captureActivityIndicator.translatesAutoresizingMaskIntoConstraints = false
        captureActivityIndicator.hidesWhenStopped = true
        captureActivityIndicator.color = .white
        captureButton.addSubview(captureActivityIndicator)

        deleteLastButton.translatesAutoresizingMaskIntoConstraints = false
        deleteLastButton.setTitle("Delete Last", for: .normal)
        deleteLastButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        deleteLastButton.tintColor = .white
        deleteLastButton.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        deleteLastButton.layer.cornerRadius = 14
        deleteLastButton.addTarget(self, action: #selector(deleteLastPhoto), for: .touchUpInside)
        overlayView.addSubview(deleteLastButton)

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

            flashView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            flashView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            flashView.topAnchor.constraint(equalTo: view.topAnchor),
            flashView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

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

            feedbackLabel.centerXAnchor.constraint(equalTo: overlayView.centerXAnchor),
            feedbackLabel.leadingAnchor.constraint(greaterThanOrEqualTo: overlayView.leadingAnchor, constant: 32),
            feedbackLabel.trailingAnchor.constraint(lessThanOrEqualTo: overlayView.trailingAnchor, constant: -32),
            feedbackLabel.bottomAnchor.constraint(equalTo: captureButton.topAnchor, constant: -24),

            captureButton.centerXAnchor.constraint(equalTo: overlayView.centerXAnchor),
            captureButton.bottomAnchor.constraint(equalTo: overlayView.bottomAnchor, constant: -28),
            captureButton.widthAnchor.constraint(equalToConstant: 72),
            captureButton.heightAnchor.constraint(equalToConstant: 72),

            captureActivityIndicator.centerXAnchor.constraint(equalTo: captureButton.centerXAnchor),
            captureActivityIndicator.centerYAnchor.constraint(equalTo: captureButton.centerYAnchor),

            deleteLastButton.leadingAnchor.constraint(equalTo: overlayView.leadingAnchor, constant: 20),
            deleteLastButton.centerYAnchor.constraint(equalTo: captureButton.centerYAnchor),
            deleteLastButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 110),
            deleteLastButton.heightAnchor.constraint(equalToConstant: 44),

            previewContainerView.trailingAnchor.constraint(equalTo: overlayView.trailingAnchor, constant: -20),
            previewContainerView.centerYAnchor.constraint(equalTo: captureButton.centerYAnchor),
            previewContainerView.widthAnchor.constraint(equalToConstant: 78),
            previewContainerView.heightAnchor.constraint(equalToConstant: 112),

            previewImageView.leadingAnchor.constraint(equalTo: previewContainerView.leadingAnchor, constant: 6),
            previewImageView.trailingAnchor.constraint(equalTo: previewContainerView.trailingAnchor, constant: -6),
            previewImageView.topAnchor.constraint(equalTo: previewContainerView.topAnchor, constant: 6),
            previewImageView.bottomAnchor.constraint(equalTo: previewContainerView.bottomAnchor, constant: -6),

            previewPlaceholderImageView.centerXAnchor.constraint(equalTo: previewContainerView.centerXAnchor),
            previewPlaceholderImageView.centerYAnchor.constraint(equalTo: previewContainerView.centerYAnchor),
            previewPlaceholderImageView.widthAnchor.constraint(equalToConstant: 24),
            previewPlaceholderImageView.heightAnchor.constraint(equalToConstant: 24),
        ])

        doneButton.isEnabled = false
        doneButton.alpha = 0.5
        deleteLastButton.isEnabled = false
        deleteLastButton.alpha = 0.5
        updateCountLabel()
        updatePreview()
        updateCaptureInteractivity()
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
                DispatchQueue.main.async {
                    self.showFeedback("Camera ready")
                    self.updateCaptureInteractivity()
                }
            } catch {
                self.captureSession.commitConfiguration()
                DispatchQueue.main.async {
                    self.delegate?.cameraCaptureViewController(self, didFailWithError: error)
                }
            }
        }
    }

    private func updateCountLabel() {
        countLabel.text = capturedPageURLs.isEmpty
            ? "No pages yet"
            : "\(capturedPageURLs.count) page\(capturedPageURLs.count == 1 ? "" : "s") captured"
    }

    private func updatePreview() {
        let hasPreview = lastPreviewImage != nil
        previewImageView.image = lastPreviewImage
        previewImageView.alpha = hasPreview ? 1.0 : 0.0
        previewPlaceholderImageView.isHidden = hasPreview
        deleteLastButton.isEnabled = !capturedPageURLs.isEmpty && !isCaptureInProgress
        deleteLastButton.alpha = deleteLastButton.isEnabled ? 1.0 : 0.5
    }

    private func updateCaptureInteractivity() {
        let canCapture = isConfigured && !isCaptureInProgress
        captureButton.isEnabled = canCapture
        captureButton.alpha = canCapture ? 1.0 : 0.65
        captureButton.imageView?.alpha = canCapture ? 1.0 : 0.0

        if isCaptureInProgress {
            captureActivityIndicator.startAnimating()
        } else {
            captureActivityIndicator.stopAnimating()
        }

        doneButton.isEnabled = !capturedPageURLs.isEmpty && !isCaptureInProgress
        doneButton.alpha = doneButton.isEnabled ? 1.0 : 0.5
        deleteLastButton.isEnabled = !capturedPageURLs.isEmpty && !isCaptureInProgress
        deleteLastButton.alpha = deleteLastButton.isEnabled ? 1.0 : 0.5
    }

    private func showFeedback(_ message: String) {
        feedbackDismissWorkItem?.cancel()
        feedbackLabel.text = "  \(message)  "
        UIView.animate(withDuration: 0.18) {
            self.feedbackLabel.alpha = 1
        }

        let workItem = DispatchWorkItem { [weak self] in
            UIView.animate(withDuration: 0.25) {
                self?.feedbackLabel.alpha = 0
            }
        }
        feedbackDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: workItem)
    }

    private func animateFlash() {
        flashView.alpha = 0
        UIView.animate(withDuration: 0.08, animations: {
            self.flashView.alpha = 0.16
        }, completion: { _ in
            UIView.animate(withDuration: 0.18) {
                self.flashView.alpha = 0
            }
        })
    }

    @objc
    private func capturePhoto() {
        guard isConfigured, !isCaptureInProgress else { return }
        isCaptureInProgress = true
        animateFlash()
        showFeedback("Capturing page…")

        let settings: AVCapturePhotoSettings
        if photoOutput.availablePhotoCodecTypes.contains(.jpeg) {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        } else {
            settings = AVCapturePhotoSettings()
        }
        settings.photoQualityPrioritization = .quality
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    @objc
    private func finishCapture() {
        delegate?.cameraCaptureViewController(self, didFinishWith: capturedPageURLs)
    }

    @objc
    private func cancelCapture() {
        ScanCaptureStorage.removeDirectory(captureDirectoryURL)
        captureDirectoryURL = nil
        capturedPageURLs = []
        lastPreviewImage = nil
        delegate?.cameraCaptureViewControllerDidCancel(self)
    }

    @objc
    private func deleteLastPhoto() {
        guard !capturedPageURLs.isEmpty, !isCaptureInProgress else { return }
        let removedURL = capturedPageURLs.removeLast()
        try? FileManager.default.removeItem(at: removedURL)
        lastPreviewImage = capturedPageURLs.last.flatMap { UIImage(contentsOfFile: $0.path) }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        showFeedback(capturedPageURLs.isEmpty ? "Removed last page" : "Last page deleted")
    }

    @objc
    private func showLastPhotoPreview() {
        guard !capturedPageURLs.isEmpty else { return }
        let image = capturedPageURLs.last.flatMap { UIImage(contentsOfFile: $0.path) } ?? lastPreviewImage
        guard let image else { return }

        let controller = CameraCapturedImagePreviewController(image: image)
        controller.modalPresentationStyle = .fullScreen
        present(controller, animated: true)
    }
}

extension CameraCaptureViewController: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            isCaptureInProgress = false
            delegate?.cameraCaptureViewController(self, didFailWithError: error)
            return
        }

        guard
            let data = photo.fileDataRepresentation()
        else {
            isCaptureInProgress = false
            delegate?.cameraCaptureViewController(self, didFailWithError: CameraCaptureError.unableToDecodePhoto)
            return
        }

        do {
            if captureDirectoryURL == nil {
                captureDirectoryURL = try ScanCaptureStorage.makeCaptureDirectory()
            }

            guard let captureDirectoryURL else {
                throw ScanCaptureStorageError.unableToPersistCapture
            }

            let fileURL = try ScanCaptureStorage.writeImageData(
                data,
                index: capturedPageURLs.count,
                directory: captureDirectoryURL
            )
            lastPreviewImage = UIImage(contentsOfFile: fileURL.path) ?? UIImage(data: data)
            capturedPageURLs.append(fileURL)
        } catch {
            isCaptureInProgress = false
            delegate?.cameraCaptureViewController(self, didFailWithError: error)
            return
        }

        isCaptureInProgress = false
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        showFeedback("Captured page \(capturedPageURLs.count)")
    }
}

private final class CameraCapturedImagePreviewController: UIViewController, UIScrollViewDelegate {
    private let image: UIImage
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let closeButton = UIButton(type: .system)

    init(image: UIImage) {
        self.image = image
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.delegate = self
        view.addSubview(scrollView)

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        scrollView.addSubview(imageView)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setTitle("Done", for: .normal)
        closeButton.tintColor = .white
        closeButton.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        closeButton.layer.cornerRadius = 14
        closeButton.contentEdgeInsets = UIEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        closeButton.addTarget(self, action: #selector(closePreview), for: .touchUpInside)
        view.addSubview(closeButton)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),

            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            closeButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
        ])
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    @objc
    private func closePreview() {
        dismiss(animated: true)
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
