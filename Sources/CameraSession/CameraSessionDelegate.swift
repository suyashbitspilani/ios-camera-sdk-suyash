import CoreMedia
import CoreVideo

public protocol CameraSessionDelegate: AnyObject {
    func cameraSession(_ session: CameraSession,
                       didOutputPixelBuffer buffer: CVPixelBuffer,
                       timestamp: CMTime)
}
