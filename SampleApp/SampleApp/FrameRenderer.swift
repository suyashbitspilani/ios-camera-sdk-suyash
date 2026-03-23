import CoreImage
import CoreVideo
import UIKit

/// Converts raw CVPixelBuffer frames to UIImage for display.
///
/// This exists to prove we're actually consuming the pixel buffer pipeline
/// end-to-end, rather than relying on AVCaptureVideoPreviewLayer (which
/// would bypass the SDK's output entirely).
final class FrameRenderer {

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Converts a CVPixelBuffer to a UIImage suitable for display.
    ///
    /// The conversion path is: CVPixelBuffer -> CIImage -> CGImage -> UIImage.
    /// We go through CGImage because CIImage-backed UIImages don't always
    /// render correctly in SwiftUI's Image view.
    func render(_ pixelBuffer: CVPixelBuffer) -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let rect = CGRect(x: 0, y: 0, width: width, height: height)

        guard let cgImage = ciContext.createCGImage(ciImage, from: rect) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }
}
