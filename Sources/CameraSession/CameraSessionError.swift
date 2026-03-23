import Foundation

public enum CameraSessionError: LocalizedError {
    case unsupportedFormat(requested: String, available: [String])
}
