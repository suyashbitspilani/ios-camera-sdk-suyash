import AVFoundation
import CoreMedia

/// Resolves the best `AVCaptureDevice.Format` for a given resolution preset
/// and target frame rate.
///
/// Rather than relying on `AVCaptureSession.sessionPreset` (which is a hint,
/// not a guarantee), this resolver iterates the device's actual supported
/// formats, matches pixel dimensions to the requested preset, and verifies
/// that at least one frame rate range covers the desired FPS.
struct FormatResolver {

    /// Result of a successful format resolution.
    struct Match {
        let format: AVCaptureDevice.Format
        let dimensions: CMVideoDimensions
    }

    /// Finds a device format whose pixel dimensions match the given preset
    /// and whose frame rate ranges include the target FPS.
    ///
    /// - Parameters:
    ///   - preset: The session preset representing the desired resolution.
    ///   - fps: Target frames per second.
    ///   - device: The capture device to query for available formats.
    ///
    /// - Throws: ``CameraSessionError/unsupportedFormat(requested:available:)``
    ///   if no matching format is found.
    ///
    /// - Returns: A ``Match`` containing the selected format and its dimensions.
    func resolve(preset: AVCaptureSession.Preset,
                 fps: Int,
                 device: AVCaptureDevice) throws -> Match {

        let targetDimensions = Self.dimensions(for: preset)
        let targetFPS = Float64(fps)

        var availableDescriptions: [String] = []

        for format in device.formats {
            let desc = CMVideoFormatDescriptionGetDimensions(format.formatDescription)

            // Collect available formats for the error message
            let fpsRanges = format.videoSupportedFrameRateRanges
            let rangeStr = fpsRanges.map { "\(Int($0.minFrameRate))-\(Int($0.maxFrameRate))fps" }
                                    .joined(separator: ", ")
            availableDescriptions.append("\(desc.width)x\(desc.height) [\(rangeStr)]")

            // Check if this format matches the requested resolution
            guard desc.width == targetDimensions.width,
                  desc.height == targetDimensions.height else {
                continue
            }

            // Check if any frame rate range includes the target FPS
            let supportsTargetFPS = fpsRanges.contains { range in
                targetFPS >= range.minFrameRate && targetFPS <= range.maxFrameRate
            }

            if supportsTargetFPS {
                return Match(format: format, dimensions: desc)
            }
        }

        // No match — build a descriptive error
        let requestedStr = "\(targetDimensions.width)x\(targetDimensions.height) @ \(fps) fps"
        throw CameraSessionError.unsupportedFormat(
            requested: requestedStr,
            available: availableDescriptions
        )
    }

    // MARK: - Preset to Dimensions Mapping

    /// Maps an `AVCaptureSession.Preset` to concrete pixel dimensions.
    ///
    /// These values match what Apple's presets target on most hardware.
    /// We need this mapping because the preset enum doesn't expose its
    /// resolution directly — we have to compare against format descriptors.
    static func dimensions(for preset: AVCaptureSession.Preset) -> CMVideoDimensions {
        switch preset {
        case .hd4K3840x2160:
            return CMVideoDimensions(width: 3840, height: 2160)
        case .hd1920x1080:
            return CMVideoDimensions(width: 1920, height: 1080)
        case .hd1280x720:
            return CMVideoDimensions(width: 1280, height: 720)
        case .vga640x480:
            return CMVideoDimensions(width: 640, height: 480)
        case .cif352x288:
            return CMVideoDimensions(width: 352, height: 288)
        case .iFrame960x540:
            return CMVideoDimensions(width: 960, height: 540)
        case .iFrame1280x720:
            return CMVideoDimensions(width: 1280, height: 720)
        default:
            // Reasonable fallback for unknown presets
            return CMVideoDimensions(width: 1920, height: 1080)
        }
    }
}
