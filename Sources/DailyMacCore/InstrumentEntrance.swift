import Foundation

/// Brief, one-shot reveals. Timing changes presentation, never the measured path.
public enum InstrumentEntrance {
    public static func progress(_ metric: MachineInstrument, elapsed: Double) -> Double {
        let timing: (delay: Double, duration: Double) = switch metric {
        case .cpu: (0, 0.76)
        case .gpu: (0.055, 0.88)
        case .battery: (0.10, 0.94)
        case .memory: (0.08, 0.90)
        case .fan: (0.14, 0.92)
        }
        let t = min(1, max(0, (elapsed - timing.delay) / timing.duration))
        return t * t * (3 - 2 * t)
    }
}
