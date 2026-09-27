import AppKit
import DailyMacCore

/// Two native signals fill one rounded screen, with no separate laptop base:
/// health above, four-step machine load below. Gray means no fresh reading.
enum MachineStatusIcon {
    enum State {
        case live(MachineStatusSignal)
        case waiting
        case paused
        case asleep
        case failed

        var accessibilityValue: String {
            switch self {
            case .live(let signal):
                let gpu = signal.gpuPercent.map { ", estimated GPU \($0)%" } ?? ""
                return "Health: \(signal.health.label). Machine load: \(signal.effort.label), CPU \(signal.cpuPercent)%\(gpu)."
            case .waiting: return "Waiting for a fresh machine reading."
            case .paused: return "Monitoring paused."
            case .asleep: return "Mac asleep."
            case .failed: return "Monitoring needs attention."
            }
        }
    }

    static func image(for state: State) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            let frame = NSBezierPath(roundedRect: NSRect(x: 1, y: 1, width: 18, height: 18), xRadius: 3.3, yRadius: 3.3)
            frame.lineWidth = 1.25
            NSColor.labelColor.withAlphaComponent(0.94).setStroke()
            frame.stroke()

            let healthColor: NSColor
            let effort: MachineSignalLevel?
            switch state {
            case .live(let signal):
                healthColor = color(for: signal.health)
                effort = signal.effort
            case .failed:
                healthColor = .systemRed
                effort = nil
            case .waiting, .paused, .asleep:
                healthColor = NSColor.secondaryLabelColor.withAlphaComponent(0.65)
                effort = nil
            }

            healthColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: 3.1, y: 11.3, width: 13.8, height: 3.5), xRadius: 1.75, yRadius: 1.75).fill()

            let effortTrack = NSRect(x: 3.1, y: 5.2, width: 13.8, height: 3.5)
            NSColor.secondaryLabelColor.withAlphaComponent(0.34).setFill()
            NSBezierPath(roundedRect: effortTrack, xRadius: 1.75, yRadius: 1.75).fill()
            if let effort {
                color(for: effort).setFill()
                let filledWidth = effortTrack.width * CGFloat(effort.rawValue) / 4
                NSBezierPath(
                    roundedRect: NSRect(x: effortTrack.minX, y: effortTrack.minY, width: filledWidth, height: effortTrack.height),
                    xRadius: 1.75, yRadius: 1.75
                ).fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// One compact instrument holds two vertical signals beside the existing
    /// CPU/GPU instrument. The original status square is unchanged.
    static func image(
        for state: State,
        average: MachineDemandAverage?,
        fanPercent: Double? = nil,
        thermalLevel: ThermalLevel? = nil
    ) -> NSImage {
        let image = NSImage(size: NSSize(width: 81, height: 20), flipped: false) { _ in
            let physicalFrame = NSBezierPath(
                roundedRect: NSRect(x: 0.8, y: 0.8, width: 16.4, height: 18.4),
                xRadius: 4.5, yRadius: 4.5
            )
            physicalFrame.lineWidth = 1.15
            NSColor.labelColor.withAlphaComponent(0.78).setStroke()
            physicalFrame.stroke()
            physicalBar(
                fraction: fanPercent.map { min(1, max(0, $0 / 100)) },
                x: 3.4,
                color: NSColor.labelColor.withAlphaComponent(0.87)
            )
            physicalBar(
                fraction: thermalFraction(thermalLevel),
                x: 10.0,
                color: thermalColor(thermalLevel)
            )

            let frame = NSBezierPath(
                roundedRect: NSRect(x: 18.8, y: 0.8, width: 39.4, height: 18.4),
                xRadius: 4.5, yRadius: 4.5
            )
            frame.lineWidth = 1.15
            NSColor.labelColor.withAlphaComponent(0.78).setStroke()
            frame.stroke()

            gauge(percent: average?.cpuPercent, x: 21.6, y: 11.2, color: adaptive(dark: 0x4F91FF, light: 0x236BE8))
            gauge(percent: average?.gpuPercent, x: 21.6, y: 4.6, color: adaptive(dark: 0x80D9FF, light: 0x149CE3))
            self.image(for: state).draw(in: NSRect(x: 61, y: 0, width: 20, height: 20))
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func gauge(percent: Int?, x: CGFloat, y: CGFloat, color: NSColor) {
        let rail = NSRect(x: x, y: y, width: 33.8, height: 4.2)
        NSColor.secondaryLabelColor.withAlphaComponent(0.30).setFill()
        NSBezierPath(roundedRect: rail, xRadius: 2.1, yRadius: 2.1).fill()
        guard let percent, percent > 0 else { return }
        let width = max(4.2, rail.width * CGFloat(min(100, percent)) / 100)
        color.setFill()
        NSBezierPath(
            roundedRect: NSRect(x: rail.minX, y: rail.minY, width: width, height: rail.height),
            xRadius: 2.1, yRadius: 2.1
        ).fill()
    }

    private static func physicalBar(fraction: Double?, x: CGFloat, color: NSColor) {
        let rail = NSRect(x: x, y: 3.1, width: 4.3, height: 13.8)
        NSColor.secondaryLabelColor.withAlphaComponent(0.30).setFill()
        NSBezierPath(roundedRect: rail, xRadius: 2.15, yRadius: 2.15).fill()
        guard let fraction, fraction > 0 else { return }
        let fillHeight = max(2.8, rail.height * CGFloat(fraction))
        let fill = NSRect(x: rail.minX, y: rail.minY, width: rail.width, height: fillHeight)
        color.setFill()
        NSBezierPath(roundedRect: fill, xRadius: min(2.15, fillHeight / 2), yRadius: min(2.15, fillHeight / 2)).fill()
    }

    /// Category steps, not a heat or power percentage. A short cool-blue fill
    /// distinguishes measured nominal pressure from missing telemetry.
    private static func thermalFraction(_ level: ThermalLevel?) -> Double? {
        switch level {
        case .nominal: 0.22
        case .fair: 0.48
        case .serious: 0.73
        case .critical: 1
        case .unknown, nil: nil
        }
    }

    private static func thermalColor(_ level: ThermalLevel?) -> NSColor {
        switch level {
        case .nominal: adaptive(dark: 0x80D9FF, light: 0x149CE3)
        case .fair: .systemYellow
        case .serious: .systemOrange
        case .critical: .systemRed
        case .unknown, nil: NSColor.secondaryLabelColor
        }
    }

    private static func adaptive(dark: UInt32, light: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                calibratedRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255,
                alpha: 1
            )
        }
    }

    private static func color(for level: MachineSignalLevel) -> NSColor {
        switch level {
        case .low: .systemGreen
        case .moderate: .systemYellow
        case .high: .systemOrange
        case .nearCapacity: .systemRed
        }
    }

    private static func color(for health: MachineHealthSignal) -> NSColor {
        switch health {
        case .comfortable: .systemGreen
        case .watch: .systemYellow
        case .pressured: .systemOrange
        case .critical: .systemRed
        }
    }
}
