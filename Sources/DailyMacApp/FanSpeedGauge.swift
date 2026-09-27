import DailyMacCore
import SwiftUI

/// Mirrors the physical instrument in the menu bar. Fan height is measured
/// RPM / reported maximum; heat height is a category, not degrees.
struct FanSpeedGauge: View {
    @EnvironmentObject private var model: AppModel

    private var fans: [FanReading]? {
        guard model.collectionState == .monitoring,
              let measuredAt = model.fanReadingsAt,
              Date().timeIntervalSince(measuredAt) < 45 else { return nil }
        return model.fanReadings
    }

    private var fastest: FanReading? {
        fans?.max(by: { $0.percentOfMaximum < $1.percentOfMaximum })
    }

    private var thermal: ThermalLevel? {
        guard model.collectionState == .monitoring,
              let sample = model.latestSystem,
              MachineStatusSignal.isFresh(sample) else { return nil }
        return sample.thermalLevel
    }

    var body: some View {
        HStack(spacing: 7) {
            HStack(alignment: .bottom, spacing: 3) {
                instrumentBar(fraction: fastest.map { $0.percentOfMaximum / 100 }, tint: .primary)
                instrumentBar(fraction: thermalFraction, tint: thermalTint)
            }
            .frame(height: 18)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text("Fan \(fastest?.speedDescription ?? "—")")
                Text("Heat \(thermalLabel)")
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.secondary)
            .fixedSize()
        }
        .padding(.horizontal, 9)
        .frame(height: 29)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.75)
        }
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(helpText)
    }

    private func instrumentBar(fraction: Double?, tint: Color) -> some View {
        ZStack(alignment: .bottom) {
            Capsule()
                .fill(Color.primary.opacity(0.16))
                .frame(width: 5, height: 18)
            if let fraction {
                Capsule()
                    .fill(tint.opacity(0.88))
                    .frame(width: 5, height: max(3, 18 * min(1, max(0, fraction))))
            }
        }
        .frame(width: 5, height: 18)
    }

    private var thermalFraction: Double? {
        switch thermal {
        case .nominal: 0.22
        case .fair: 0.48
        case .serious: 0.73
        case .critical: 1
        case .unknown, nil: nil
        }
    }

    private var thermalTint: Color {
        switch thermal {
        case .nominal: MachinePalette.graphics
        case .fair: .yellow
        case .serious: .orange
        case .critical: .red
        case .unknown, nil: .secondary
        }
    }

    private var thermalLabel: String {
        switch thermal {
        case .nominal: "Normal"
        case .fair: "Managed"
        case .serious: "High"
        case .critical: "Critical"
        case .unknown, nil: "—"
        }
    }

    private var helpText: String {
        let fanDescription = fastest.map {
            "Fan: \(Int($0.rpm.rounded())) RPM, \(Int($0.percentOfMaximum.rounded()))% of its reported maximum speed."
        } ?? "Fan RPM unavailable."
        return "\(fanDescription) macOS thermal pressure: \(thermalLabel.lowercased()). The heat bar is categorical, not a temperature or fan-power meter."
    }
}
