import SwiftUI
@preconcurrency import AVFoundation
import UIKit

enum ReceiptPhotoSource: String, Identifiable {
    case camera

    var id: String { rawValue }
}

/// A focused camera surface for one-off document capture. The system camera
/// controller is intentionally not used here: Payday needs the live preview,
/// framing guide, and single shutter action to stay inside the entry flow.
struct PaydayCameraView: UIViewControllerRepresentable {
    let title: String
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isCameraAvailable: Bool {
        AVCaptureDevice.default(for: .video) != nil
    }

    func makeUIViewController(context: Context) -> PaydayCameraViewController {
        PaydayCameraViewController(
            title: title,
            onImage: onImage,
            onDismiss: { dismiss() }
        )
    }

    func updateUIViewController(_ controller: PaydayCameraViewController, context: Context) {
        controller.titleText = title
    }
}

final class PaydayCameraViewController: UIViewController, @preconcurrency AVCapturePhotoCaptureDelegate {
    var titleText: String {
        didSet { titleLabel.text = titleText }
    }

    private let onImage: (UIImage) -> Void
    private let onDismiss: () -> Void
    private let cameraSession = CameraSessionController()
    private let previewView = UIView()
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let shutterButton = UIButton(type: .custom)
    private let cancelButton = UIButton(type: .system)
    private let openSettingsButton = UIButton(type: .system)
    private let guideView = CameraGuideView()
    private let bottomBar = UIView()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var isConfigured = false
    private var isCapturing = false

    init(
        title: String,
        onImage: @escaping (UIImage) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.titleText = title
        self.onImage = onImage
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureInterface()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        requestCameraAccess()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        cameraSession.stop()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = previewView.bounds
    }

    private func configureInterface() {
        previewView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(previewView)
        NSLayoutConstraint.activate([
            previewView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            previewView.topAnchor.constraint(equalTo: view.topAnchor),
            previewView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        guideView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(guideView)
        NSLayoutConstraint.activate([
            guideView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            guideView.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -36),
            guideView.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.84),
            guideView.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.42)
        ])

        titleLabel.text = titleText
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleLabel)

        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.setTitleColor(.white, for: .normal)
        cancelButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        cancelButton.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cancelButton)

        NSLayoutConstraint.activate([
            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            cancelButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            cancelButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor)
        ])

        bottomBar.backgroundColor = UIColor.black.withAlphaComponent(0.64)
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bottomBar)

        NSLayoutConstraint.activate([
            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 148)
        ])

        shutterButton.backgroundColor = .white
        shutterButton.layer.cornerRadius = 38
        shutterButton.layer.borderColor = UIColor.white.withAlphaComponent(0.45).cgColor
        shutterButton.layer.borderWidth = 5
        shutterButton.accessibilityLabel = "Take photo"
        shutterButton.isEnabled = false
        shutterButton.addTarget(self, action: #selector(capturePhoto), for: .touchUpInside)
        shutterButton.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(shutterButton)

        NSLayoutConstraint.activate([
            shutterButton.centerXAnchor.constraint(equalTo: bottomBar.centerXAnchor),
            shutterButton.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            shutterButton.widthAnchor.constraint(equalToConstant: 76),
            shutterButton.heightAnchor.constraint(equalToConstant: 76)
        ])

        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 15, weight: .medium)
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.isHidden = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        openSettingsButton.setTitle("Open Settings", for: .normal)
        openSettingsButton.setTitleColor(.white, for: .normal)
        openSettingsButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        openSettingsButton.addTarget(self, action: #selector(openSettings), for: .touchUpInside)
        openSettingsButton.isHidden = true
        openSettingsButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(openSettingsButton)

        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            openSettingsButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            openSettingsButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 16)
        ])
    }

    private func requestCameraAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted {
                        self.configureSession()
                    } else {
                        self.showPermissionDenied()
                    }
                }
            }
        case .denied, .restricted:
            showPermissionDenied()
        @unknown default:
            showPermissionDenied()
        }
    }

    private func configureSession() {
        shutterButton.isHidden = false
        shutterButton.isEnabled = false
        statusLabel.isHidden = true
        openSettingsButton.isHidden = true

        cameraSession.configure { @MainActor [weak self] succeeded in
            guard let self else { return }
            guard succeeded else {
                showCameraUnavailable()
                return
            }

            isConfigured = true
            if previewLayer == nil {
                let layer = AVCaptureVideoPreviewLayer(session: cameraSession.session)
                layer.videoGravity = .resizeAspectFill
                layer.frame = previewView.bounds
                previewView.layer.addSublayer(layer)
                previewLayer = layer
            }
            shutterButton.isHidden = false
            shutterButton.isEnabled = true
            statusLabel.isHidden = true
            openSettingsButton.isHidden = true
        }
    }

    private func showCameraUnavailable() {
        statusLabel.text = "Payday cannot access the camera on this device."
        statusLabel.isHidden = false
        shutterButton.isHidden = true
    }

    private func showPermissionDenied() {
        isConfigured = false
        cameraSession.stop()
        statusLabel.text = "Allow camera access in Settings to take a photo."
        statusLabel.isHidden = false
        openSettingsButton.isHidden = false
        shutterButton.isHidden = true
    }

    @objc private func capturePhoto() {
        guard isConfigured, !isCapturing else { return }
        isCapturing = true
        shutterButton.isEnabled = false
        let settings = AVCapturePhotoSettings()
        settings.flashMode = .off
        cameraSession.photoOutput.capturePhoto(with: settings, delegate: self)
    }

    @objc private func cancel() {
        onDismiss()
    }

    @objc private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    @objc private func appDidBecomeActive() {
        guard viewIfLoaded?.window != nil else { return }
        requestCameraAccess()
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        guard error == nil,
              let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data)
        else {
            DispatchQueue.main.async { [weak self] in
                self?.isCapturing = false
                self?.shutterButton.isEnabled = true
                self?.statusLabel.text = "Payday could not capture that photo. Try again."
                self?.statusLabel.isHidden = false
            }
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            onImage(image)
            onDismiss()
        }
    }
}

private final class CameraSessionController: @unchecked Sendable {
    let session = AVCaptureSession()
    let photoOutput = AVCapturePhotoOutput()

    private let queue = DispatchQueue(label: "com.szakacsmedia.payday.camera-session")
    private var isConfigured = false

    func configure(completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        queue.async { [self] in
            if !isConfigured {
                session.beginConfiguration()
                session.sessionPreset = .photo

                if let camera = AVCaptureDevice.default(
                    .builtInWideAngleCamera,
                    for: .video,
                    position: .back
                ),
                   let input = try? AVCaptureDeviceInput(device: camera),
                   session.canAddInput(input),
                   session.canAddOutput(photoOutput)
                {
                    session.addInput(input)
                    session.addOutput(photoOutput)
                    isConfigured = true
                }

                session.commitConfiguration()
            }

            if isConfigured, !session.isRunning {
                session.startRunning()
            }
            let succeeded = isConfigured
            Task { @MainActor in
                completion(succeeded)
            }
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning {
                session.stopRunning()
            }
        }
    }
}

private final class CameraGuideView: UIView {
    override func draw(_ rect: CGRect) {
        UIColor.white.withAlphaComponent(0.84).setStroke()
        let path = UIBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerRadius: 18)
        path.lineWidth = 2
        path.stroke()
    }
}
