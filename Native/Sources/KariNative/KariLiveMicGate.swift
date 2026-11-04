import Foundation

enum LiveMicDisposition: Equatable {
    case upload
    case holdLocalTurn
    case drop
}

enum LiveMicGate {
    static func disposition(speaking: Bool, responseOpen: Bool, now: TimeInterval, echoUntil: TimeInterval) -> LiveMicDisposition {
        if speaking || responseOpen { return .holdLocalTurn }
        if now < echoUntil { return .drop }
        return .upload
    }
}
