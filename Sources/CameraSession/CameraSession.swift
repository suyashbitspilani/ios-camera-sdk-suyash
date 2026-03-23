import AVFoundation
import CoreMedia
import CoreVideo
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
public final class CameraSession {

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
        logger.info("CameraSession initialized, delegate queue: \(self.delegateQueue.label)")
    }

    deinit {
        logger.info("CameraSession deinit — tearing down capture session")

        captureSession.stopRunning()

        // Remove all inputs
        for input in captureSession.inputs {
            captureSession.removeInput(input)
        }

        // Remove all outputs
        for output in captureSession.outputs {
            captureSession.removeOutput(output)
        }

        logger.info("CameraSession cleanup complete")
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

        logger.info("Configuring for \(resolution.rawValue) @ \(fps) fps")

        // Implementation wired up in commit 6
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
