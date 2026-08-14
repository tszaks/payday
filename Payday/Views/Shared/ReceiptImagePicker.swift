import SwiftUI
@preconcurrency import AVFoundation
import OSLog
import UIKit

private enum PaydayCameraDiagnostics {
    static let logger = Logger(subsystem: "com.szakacsmedia.payday", category: "Camera")
    static let buildMarker = "camera-analysis-2026-08-14-v2"
}

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
    private var previewLayer: AVCaptureVideoPreviewLayer?
    // These two flags are UI state and are only read or written on the main actor.
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
        PaydayCameraDiagnostics.logger.notice(
            "Camera opened. marker=\(PaydayCameraDiagnostics.buildMarker, privacy: .public) iosAppOnMac=\(ProcessInfo.processInfo.isiOSAppOnMac)"
        )
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

        titleLabel.text = titleText
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleLabel)

        let cancelSymbol = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        cancelButton.setImage(
            UIImage(systemName: "chevron.left", withConfiguration: cancelSymbol),
            for: .normal
        )
        cancelButton.tintColor = .white
        cancelButton.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        cancelButton.layer.cornerRadius = 22
        cancelButton.accessibilityLabel = "Cancel"
        cancelButton.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cancelButton)

        NSLayoutConstraint.activate([
            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16)
        ])

        shutterButton.backgroundColor = .white
        shutterButton.layer.cornerRadius = 38
        shutterButton.layer.borderColor = UIColor.white.withAlphaComponent(0.45).cgColor
        shutterButton.layer.borderWidth = 5
        shutterButton.accessibilityLabel = "Take photo"
        shutterButton.isEnabled = false
        shutterButton.addTarget(self, action: #selector(capturePhoto), for: .touchUpInside)
        shutterButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(shutterButton)

        NSLayoutConstraint.activate([
            shutterButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            shutterButton.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                constant: -24
            ),
            shutterButton.widthAnchor.constraint(equalToConstant: 76),
            shutterButton.heightAnchor.constraint(equalToConstant: 76),
            cancelButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            cancelButton.centerYAnchor.constraint(equalTo: shutterButton.centerYAnchor),
            cancelButton.widthAnchor.constraint(equalToConstant: 44),
            cancelButton.heightAnchor.constraint(equalToConstant: 44)
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
        prepareForCameraStart()
        let authorization = AVCaptureDevice.authorizationStatus(for: .video)
        PaydayCameraDiagnostics.logger.notice(
            "Camera authorization checked. status=\(authorization.rawValue)"
        )

        switch authorization {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                PaydayCameraDiagnostics.logger.notice(
                    "Camera authorization request completed. granted=\(granted)"
                )
                if granted {
                    // Camera configuration immediately enters the session queue.
                    self.cameraSession.configure { @MainActor [weak self] succeeded in
                        self?.finishCameraStart(succeeded: succeeded)
                    }
                } else {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
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

    private func prepareForCameraStart() {
        shutterButton.isHidden = false
        shutterButton.isEnabled = false
        statusLabel.isHidden = true
        openSettingsButton.isHidden = true
    }

    private func configureSession() {
        cameraSession.configure { @MainActor [weak self] succeeded in
            self?.finishCameraStart(succeeded: succeeded)
        }
    }

    private func finishCameraStart(succeeded: Bool) {
        PaydayCameraDiagnostics.logger.notice(
            "Camera start returned to UI. succeeded=\(succeeded)"
        )
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
        PaydayCameraDiagnostics.logger.notice("Photo capture requested")
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
            let failure = error.map { String(describing: type(of: $0)) } ?? "image-data-unavailable"
            PaydayCameraDiagnostics.logger.error(
                "Photo capture failed. reason=\(failure, privacy: .public)"
            )
            DispatchQueue.main.async { [weak self] in
                self?.isCapturing = false
                self?.shutterButton.isEnabled = true
                self?.statusLabel.text = "Payday could not capture that photo. Try again."
                self?.statusLabel.isHidden = false
            }
            return
        }

        PaydayCameraDiagnostics.logger.notice(
            "Photo capture completed. jpegBytes=\(data.count) pixels=\(Int(image.size.width))x\(Int(image.size.height))"
        )
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

    // All AVCaptureSession work and session configuration state live on this queue.
    private let sessionQueue = DispatchQueue(label: "app.payday.camera.session")
    private var isConfigured = false

    func configure(completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        sessionQueue.async { [self] in
            let configurationStartedAt = Date()
            PaydayCameraDiagnostics.logger.notice(
                "Camera session queue entered. configured=\(self.isConfigured) running=\(self.session.isRunning)"
            )
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
                    PaydayCameraDiagnostics.logger.notice(
                        "Camera selected. name=\(camera.localizedName, privacy: .public) type=\(camera.deviceType.rawValue, privacy: .public) position=\(camera.position.rawValue) connected=\(camera.isConnected) suspended=\(camera.isSuspended)"
                    )
                    session.addInput(input)
                    session.addOutput(photoOutput)
                    isConfigured = true
                } else {
                    PaydayCameraDiagnostics.logger.error(
                        "Built-in back wide-angle camera configuration failed"
                    )
                }

                session.commitConfiguration()
                let configurationMilliseconds = Int(Date().timeIntervalSince(configurationStartedAt) * 1_000)
                PaydayCameraDiagnostics.logger.notice(
                    "Camera configuration committed. succeeded=\(self.isConfigured) elapsedMs=\(configurationMilliseconds)"
                )
            }

            if isConfigured, !session.isRunning {
                let startRunningAt = Date()
                PaydayCameraDiagnostics.logger.notice("Camera startRunning beginning")
                session.startRunning()
                let startMilliseconds = Int(Date().timeIntervalSince(startRunningAt) * 1_000)
                PaydayCameraDiagnostics.logger.notice(
                    "Camera startRunning completed. running=\(self.session.isRunning) elapsedMs=\(startMilliseconds)"
                )
            }
            let succeeded = isConfigured
            Task { @MainActor in
                completion(succeeded)
            }
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            if session.isRunning {
                let stopRunningAt = Date()
                PaydayCameraDiagnostics.logger.notice("Camera stopRunning beginning")
                session.stopRunning()
                let stopMilliseconds = Int(Date().timeIntervalSince(stopRunningAt) * 1_000)
                PaydayCameraDiagnostics.logger.notice(
                    "Camera stopRunning completed. elapsedMs=\(stopMilliseconds)"
                )
            }
        }
    }
}
