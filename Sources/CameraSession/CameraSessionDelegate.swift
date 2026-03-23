import CoreMedia
import CoreVideo

/// Delegate protocol for receiving raw camera frames from a ``CameraSession``.
///
/// Conforming objects receive pixel buffers as they are captured, along with
/// their presentation timestamps. The callback queue is determined by the
/// `delegateQueue` parameter passed to ``CameraSession/init(delegateQueue:)``.
///
/// ```swift
/// class Processor: CameraSessionDelegate {
///     func cameraSession(_ session: CameraSession,
///                        didOutputPixelBuffer buffer: CVPixelBuffer,
///                        timestamp: CMTime) {
///         // Run your CV pipeline on the buffer here
///     }
/// }
/// ```
@available(iOS 15.0, *)
public protocol CameraSessionDelegate: AnyObject {

    /// Called each time a new video frame is captured.
    ///
    /// - Parameters:
    ///   - session: The camera session that produced the frame.
    ///   - buffer: A pixel buffer containing the raw image data.
    ///             Retain it if you need it beyond this call's scope.
    ///   - timestamp: Presentation timestamp of the frame, suitable for
    ///                synchronization with audio or other sensor data.
    ///
    /// - Note: This method fires on the queue specified at init time.
    ///         It is safe to call ``CameraSession/stop()`` from within
    ///         this callback without risk of deadlock.
    func cameraSession(_ session: CameraSession,
                       didOutputPixelBuffer buffer: CVPixelBuffer,
                       timestamp: CMTime)
}
