import Foundation

/// Presentation-only state: no telemetry, coordinates, or identifiers are persisted.
public struct NotchInteraction {
    public enum Phase { case hidden, preview, expanded }
    public private(set) var phase: Phase = .hidden
    private var enteredAt: TimeInterval?
    private var exitedAt: TimeInterval?
    private var requiresExit = false
    public init() {}

    public mutating func pointer(at time: TimeInterval, inActivation: Bool, inSurface: Bool) {
        guard phase != .expanded else { return }
        if requiresExit {
            if !inActivation && !inSurface { requiresExit = false }
            return
        }
        if phase == .hidden {
            if inActivation {
                if enteredAt == nil { enteredAt = time }
                if time - (enteredAt ?? time) >= 0.3 { phase = .preview; enteredAt = nil }
            } else { enteredAt = nil }
        } else if inActivation || inSurface {
            exitedAt = nil
        } else {
            if exitedAt == nil { exitedAt = time }
            if time - (exitedAt ?? time) >= 0.2 { dismiss() }
        }
    }

    public var needsDeadline: Bool { enteredAt != nil || exitedAt != nil }
    public mutating func expand() {
        phase = .expanded
        enteredAt = nil
        exitedAt = nil
    }
    public mutating func dismiss() {
        phase = .hidden
        enteredAt = nil
        exitedAt = nil
        requiresExit = true
    }
}

public enum NotchGeometry {
    /// The activation target occupies only the housing's horizontal span.
    public static func activation(screen: CGRect, topInset: CGFloat, left: CGRect?, right: CGRect?) -> CGRect? {
        guard topInset > 0, let left, let right,
              left.maxX < right.minX, left.maxX >= screen.minX, right.minX <= screen.maxX else { return nil }
        return CGRect(x: left.maxX, y: screen.maxY - topInset,
                      width: right.minX - left.maxX, height: topInset)
    }

    public static func panel(screen: CGRect, visible: CGRect, activation: CGRect?, size: CGSize) -> CGRect {
        let width = min(size.width, max(1, visible.width - 16))
        let top = min(activation?.minY ?? visible.maxY, visible.maxY)
        let height = min(size.height, max(1, top - visible.minY - 8))
        let center = activation?.midX ?? screen.midX
        let x = min(max(center - width / 2, visible.minX + 8), visible.maxX - width - 8)
        return CGRect(x: x, y: top - height, width: width, height: height)
    }
}
