import SwiftUI
import AVFoundation
import CoreMedia
import CoreVideo

/// Minimal integration demo for CameraSession.
///
/// Shows a live camera preview (rendered from pixel buffers, NOT from
/// AVCaptureVideoPreviewLayer), a frame counter, and the latest timestamp.
/// The entire CameraSession integration is under 10 lines of setup code.
@available(iOS 15.0, *)
struct ContentView: View {

    @StateObject private var viewModel = CameraViewModel()

    var body: some View {
        VStack(spacing: 16) {
            // Live preview from pixel buffers
            if let image = viewModel.latestImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 500)
                    .clipped()
            } else {
                Rectangle()
                    .fill(Color.black)
                    .frame(height: 300)
                    .overlay(Text("Waiting for frames...")
                        .foregroundColor(.white))
            }

            HStack(spacing: 24) {
                VStack {
                    Text("Frames")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(viewModel.frameCount)")
                        .font(.title2.monospacedDigit())
                }
                VStack {
                    Text("Timestamp")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(String(format: "%.3f s", viewModel.lastTimestamp))
                        .font(.title2.monospacedDigit())
                }
            }
            .padding()
        }
        .padding()
        .onAppear {
            viewModel.requestPermissionAndStart()
        }
        .onDisappear {
            viewModel.stop()
        }
    }
}

// MARK: - ViewModel

/// Bridges CameraSession to SwiftUI. This is where the <10 lines of
/// integration code live.
@available(iOS 15.0, *)
final class CameraViewModel: NSObject, ObservableObject, CameraSessionDelegate {

    @Published var latestImage: UIImage?
    @Published var frameCount: Int = 0
    @Published var lastTimestamp: Double = 0

    private var cameraSession: CameraSession?
    private let renderer = FrameRenderer()

    func requestPermissionAndStart() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard granted else { return }
            DispatchQueue.main.async {
                self?.startCamera()
            }
        }
    }

    // --- CameraSession integration: 5 lines of real setup code ---
    private func startCamera() {
        let session = CameraSession(delegateQueue: .main)
        session.delegate = self
        try? session.configure(resolution: .hd1280x720, fps: 30)
        session.start()
        cameraSession = session
    }

    func stop() {
        cameraSession?.stop()
        cameraSession = nil
    }

    // MARK: - CameraSessionDelegate

    func cameraSession(_ session: CameraSession,
                       didOutputPixelBuffer buffer: CVPixelBuffer,
                       timestamp: CMTime) {
        frameCount += 1
        lastTimestamp = CMTimeGetSeconds(timestamp)

        // Render every 3rd frame to keep UI responsive
        if frameCount % 3 == 0 {
            latestImage = renderer.render(buffer)
        }
    }
}

// Note: CameraSession and CameraSessionDelegate would normally come from
// `import CameraSession`. In this sample app they're referenced directly
// since the app lives alongside the package source.
