import Foundation

/// Errors thrown during ``CameraSession`` configuration.
///
/// These errors indicate hardware or format incompatibilities rather than
/// programming mistakes. Handle them by falling back to a different preset
/// or informing the user that their device doesn't support the requested config.
public enum CameraSessionError: LocalizedError {

    /// The requested resolution + FPS combination is not supported by any
    /// format on the current capture device.
    ///
    /// - Parameters:
    ///   - requested: A human-readable description of the requested config,
    ///                e.g. `"1920x1080 @ 240 fps"`.
    ///   - available: A list of format descriptions the device actually supports,
    ///                so the caller can pick a valid alternative.
    case unsupportedFormat(requested: String, available: [String])

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let requested, let available):
            let list = available.isEmpty
                ? "none"
                : available.joined(separator: ", ")
            return "Unsupported format: \(requested). Available: [\(list)]"
        }
    }
}
