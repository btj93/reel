import ApplicationServices
import Foundation

/// Typed wrapper for AXError codes, categorized by recovery strategy.
public enum AXCallError: Error, Sendable {
    /// Window no longer exists — remove from tracking immediately.
    case elementInvalid
    /// App is busy or unresponsive — retry next frame.
    case appUnresponsive
    /// Attribute not supported by this app — skip permanently.
    case unsupported
    /// Accessibility permission revoked — pause WM, show alert.
    case permissionDenied
    /// Generic/transient failure — retry once.
    case transientFailure(AXError)

    public static func from(_ error: AXError) -> AXCallError {
        switch error {
        case .success:
            fatalError("AXCallError.from called with .success")
        case .invalidUIElement, .invalidUIElementObserver:
            return .elementInvalid
        case .cannotComplete:
            return .appUnresponsive
        case .attributeUnsupported, .notImplemented, .actionUnsupported,
             .notificationUnsupported, .parameterizedAttributeUnsupported:
            return .unsupported
        case .apiDisabled:
            return .permissionDenied
        case .notificationAlreadyRegistered:
            return .transientFailure(error)
        default:
            return .transientFailure(error)
        }
    }

    public var isRetryable: Bool {
        switch self {
        case .appUnresponsive, .transientFailure:
            return true
        default:
            return false
        }
    }
}

/// Result type alias for AX operations.
public typealias AXResult<T> = Result<T, AXCallError>
