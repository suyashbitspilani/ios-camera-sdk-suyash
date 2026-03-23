import AVFoundation
import CoreMedia
import CoreVideo

public final class CameraSession {
    public weak var delegate: CameraSessionDelegate?

    public init(delegateQueue: DispatchQueue? = nil) {
    }
}
