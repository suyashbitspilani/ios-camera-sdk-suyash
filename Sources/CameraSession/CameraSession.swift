import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import os

/// A reusable camera capture module that manages an `AVCaptureSession` and
/// delivers raw pixel buffers through its delegate.
///
/// `CameraSession` handles device discovery, format negotiation, and
/// thread-safe session lifecycle. It is designed for integration into
/// computer vision and AR pipelines where direct pixel buffer access is
/// required rather than a preview layer.
///
/// ```swift
/// let camera = CameraSession(delegateQueue: processingQueue)
/// camera.delegate = self
/// try camera.configure(resolution: .hd1920x1080, fps: 30)
/// camera.start()
/// ```
///
/// - Important: All AVCaptureSession work runs on an internal serial queue.
///   `start()` and `stop()` are non-blocking and safe to call from any queue,
///   including from within the delegate callback.
@available(iOS 15.0, *)
public final class CameraSession: NSObject {

    // MARK: - State Machine

    /// Internal session lifecycle states. Transitions happen only on `sessionQueue`.
    private enum State: String {
        case idle
        case configured
        case running
        case stopping
    }

    // MARK: - Properties

    /// Delegate that receives captured pixel buffers.
    public weak var delegate: CameraSessionDelegate?

    private let sessionQueue = DispatchQueue(label: "com.flam.camerasession.session",
                                             qos: .userInitiated)
    private let delegateQueue: DispatchQueue

    private let captureSession = AVCaptureSession()
    private var currentDevice: AVCaptureDevice?
    private var deviceInput: AVCaptureDeviceInput?
    private var videoOutput: AVCaptureVideoDataOutput?

    private var state: State = .idle

    private let logger = Logger(subsystem: "com.flam.camerasession", category: "session")
    private let signpostLog = OSLog(subsystem: "com.flam.camerasession", category: .pointsOfInterest)

    private let formatResolver = FormatResolver()

    // MARK: - Init

    /// Creates a new camera session.
    ///
    /// - Parameter delegateQueue: The dispatch queue on which delegate callbacks
    ///   will fire. Pass `nil` (the default) to receive callbacks on the main queue.
    ///
    /// ```swift
    /// // Callbacks on a background queue:
    /// let session = CameraSession(delegateQueue: myQueue)
    ///
    /// // Callbacks on the main queue (default):
    /// let session = CameraSession()
    /// ```
    public init(delegateQueue: DispatchQueue? = nil) {
        self.delegateQueue = delegateQueue ?? .main
        super.init()
        logger.info("CameraSession initialized, delegate queue: \(self.delegateQueue.label)")
        registerInterruptionObservers()
    }

    deinit {
        logger.info("CameraSession deinit — tearing down capture session")

        NotificationCenter.default.removeObserver(self)
        captureSession.stopRunning()

        for input in captureSession.inputs {
            captureSession.removeInput(input)
        }
        for output in captureSession.outputs {
            captureSession.removeOutput(output)
        }

        logger.info("CameraSession cleanup complete")
    }

    // MARK: - Interruption Handling

    private func registerInterruptionObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionWasInterrupted(_:)),
            name: AVCaptureSession.wasInterruptedNotification,
            object: captureSession
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionInterruptionEnded(_:)),
            name: AVCaptureSession.interruptionEndedNotification,
            object: captureSession
        )
    }

    @objc private func sessionWasInterrupted(_ notification: Notification) {
        guard let reasonValue = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int,
              let reason = AVCaptureSession.InterruptionReason(rawValue: reasonValue) else {
            logger.warning("Capture session interrupted (unknown reason)")
            return
        }

        switch reason {
        case .videoDeviceNotAvailableInBackground:
            logger.info("Session interrupted: app entered background")
        case .audioDeviceInUseByAnotherClient:
            logger.info("Session interrupted: audio device in use by another client")
        case .videoDeviceInUseByAnotherClient:
            logger.warning("Session interrupted: camera in use by another app")
        case .videoDeviceNotAvailableWithMultipleForegroundApps:
            logger.info("Session interrupted: multitasking (Slide Over / Split View)")
        case .videoDeviceNotAvailableDueToSystemPressure:
            logger.warning("Session interrupted: system thermal pressure")
        @unknown default:
            logger.warning("Session interrupted: unrecognized reason (\(reasonValue))")
        }
    }

    @objc private func sessionInterruptionEnded(_ notification: Notification) {
        logger.info("Session interruption ended")

        // Auto-restart if we were running before the interruption
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.state == .running && !self.captureSession.isRunning {
                self.logger.info("Auto-restarting session after interruption")
                self.captureSession.startRunning()
            }
        }
    }

    // MARK: - Public API

    /// Configures the capture device for the given resolution and frame rate.
    ///
    /// This method discovers the back camera, finds a matching device format
    /// by iterating available formats and frame rate ranges, and locks the
    /// device to apply the configuration. The session preset is set to
    /// `.inputPriority` so the manually selected format takes precedence.
    ///
    /// - Parameters:
    ///   - resolution: The desired capture resolution as an `AVCaptureSession.Preset`.
    ///   - fps: The desired frames per second. Must fall within a supported
    ///          frame rate range for the matching format.
    ///
    /// - Throws: ``CameraSessionError/unsupportedFormat(requested:available:)``
    ///   if no device format matches the requested resolution and FPS.
    ///
    /// ```swift
    /// try session.configure(resolution: .hd1920x1080, fps: 30)
    /// ```
    ///
    /// - Note: Must be called before `start()`. Do not call while the session
    ///   is running — stop first, then reconfigure.
    public func configure(resolution: AVCaptureSession.Preset, fps: Int) throws {
        guard state == .idle || state == .configured else {
            logger.warning("configure() called in invalid state: \(self.state.rawValue)")
            return
        }

        let signpostID = OSSignpostID(log: signpostLog)
        os_signpost(.begin, log: signpostLog, name: "configure", signpostID: signpostID)
        defer {
            os_signpost(.end, log: signpostLog, name: "configure", signpostID: signpostID)
        }

        logger.info("Configuring for \(resolution.rawValue) @ \(fps) fps")

        // Discover the back camera
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                    for: .video,
                                                    position: .back) else {
            let dims = FormatResolver.dimensions(for: resolution)
            throw CameraSessionError.unsupportedFormat(
                requested: "\(dims.width)x\(dims.height) @ \(fps) fps",
                available: []
            )
        }

        // Resolve a matching format for the requested resolution + FPS
        let match = try formatResolver.resolve(preset: resolution, fps: fps, device: device)
        logger.info("Resolved format: \(match.dimensions.width)x\(match.dimensions.height)")

        // Tear down any existing input before reconfiguring
        captureSession.beginConfiguration()

        if let existingInput = deviceInput {
            captureSession.removeInput(existingInput)
        }

        // Add the device as input
        let input = try AVCaptureDeviceInput(device: device)
        guard captureSession.canAddInput(input) else {
            captureSession.commitConfiguration()
            let dims = FormatResolver.dimensions(for: resolution)
            throw CameraSessionError.unsupportedFormat(
                requested: "\(dims.width)x\(dims.height) @ \(fps) fps",
                available: ["Device input could not be added to session"]
            )
        }
        captureSession.addInput(input)
        deviceInput = input
        currentDevice = device

        // Use inputPriority so our manual format selection takes precedence
        captureSession.sessionPreset = .inputPriority

        // Lock the device and apply format + frame duration
        try device.lockForConfiguration()
        device.activeFormat = match.format
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        device.unlockForConfiguration()

        // Set up video data output for pixel buffer delivery
        if let existingOutput = videoOutput {
            captureSession.removeOutput(existingOutput)
        }

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        output.setSampleBufferDelegate(self, queue: sessionQueue)

        guard captureSession.canAddOutput(output) else {
            captureSession.commitConfiguration()
            let dims = FormatResolver.dimensions(for: resolution)
            throw CameraSessionError.unsupportedFormat(
                requested: "\(dims.width)x\(dims.height) @ \(fps) fps",
                available: ["Video output could not be added to session"]
            )
        }
        captureSession.addOutput(output)
        videoOutput = output

        captureSession.commitConfiguration()

        logger.info("Device configured: \(match.dimensions.width)x\(match.dimensions.height) @ \(fps) fps")
        state = .configured
    }

    /// Starts the capture session asynchronously.
    ///
    /// The session begins delivering pixel buffers to the delegate once
    /// hardware warm-up completes. This method returns immediately —
    /// actual capture start happens on an internal serial queue.
    ///
    /// - Important: You must call ``configure(resolution:fps:)`` before starting.
    ///   Calling `start()` from any queue (including the delegate callback) is safe.
    ///
    /// ```swift
    /// session.start()
    /// ```
    public func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.state == .configured else {
                self.logger.warning("start() ignored — current state: \(self.state.rawValue)")
                return
            }
            self.logger.info("Starting capture session")
            self.state = .running
            self.captureSession.startRunning()
        }
    }

    /// Stops the capture session asynchronously.
    ///
    /// Pixel buffer delivery stops after the session finishes winding down.
    /// This method returns immediately. It is safe to call from any queue,
    /// including from within the ``CameraSessionDelegate`` callback.
    ///
    /// ```swift
    /// // Safe to call from delegate callback:
    /// func cameraSession(_ session: CameraSession, ...) {
    ///     session.stop() // no deadlock
    /// }
    /// ```
    public func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.state == .running else {
                self.logger.warning("stop() ignored — current state: \(self.state.rawValue)")
                return
            }
            self.state = .stopping
            self.logger.info("Stopping capture session")
            self.captureSession.stopRunning()
            self.state = .configured
            self.logger.info("Capture session stopped")
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

@available(iOS 15.0, *)
extension CameraSession: AVCaptureVideoDataOutputSampleBufferDelegate {

    public func captureOutput(_ output: AVCaptureOutput,
                              didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        guard state == .running else { return }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            logger.warning("Failed to get pixel buffer from sample buffer")
            return
        }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        delegateQueue.async { [weak self] in
            guard let self else { return }
            self.delegate?.cameraSession(self,
                                         didOutputPixelBuffer: pixelBuffer,
                                         timestamp: timestamp)
        }
    }

    public func captureOutput(_ output: AVCaptureOutput,
                              didDrop sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        logger.debug("Dropped frame")
    }
}
