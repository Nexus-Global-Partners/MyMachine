import DailyMacCore
import SwiftUI

struct DiagnosisActionButton: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Button {
            model.diagnoseMachine()
        } label: {
            HStack(spacing: 6) {
                if model.diagnosisState.isPreparing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 13, height: 13)
                } else {
                    Image(systemName: model.diagnosisState.symbol)
                }
                Text(model.diagnosisState.buttonTitle)
                    .lineLimit(1)
            }
        }
        .buttonStyle(GlassySecondaryButtonStyle())
        .disabled(model.diagnosisState.isPreparing)
        .help(model.diagnosisState.detail)
        .accessibilityHint(model.diagnosisState.detail)
    }
}

struct MonitoringRangePickerControl: View {
    let selection: MonitoringRange
    let itemWidth: CGFloat
    let onSelect: (MonitoringRange) -> Void

    init(
        selection: MonitoringRange,
        itemWidth: CGFloat = 38,
        onSelect: @escaping (MonitoringRange) -> Void
    ) {
        self.selection = selection
        self.itemWidth = itemWidth
        self.onSelect = onSelect
    }

    var body: some View {
        HStack(spacing: 1) {
            ForEach(MonitoringRange.allCases) { range in
                Button {
                    onSelect(range)
                } label: {
                    Text(shortLabel(for: range))
                        .font(.caption.weight(range == selection ? .semibold : .medium))
                        .foregroundStyle(range == selection ? Color.accentColor : Color.secondary.opacity(0.90))
                        .frame(width: itemWidth, height: 23)
                        .background {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(range == selection ? Color.accentColor.opacity(0.16) : .clear)
                                .overlay {
                                    if range == selection {
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .stroke(Color.accentColor.opacity(0.24), lineWidth: 0.7)
                                    }
                                }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(range.label)
                .accessibilityAddTraits(range == selection ? .isSelected : [])
            }
        }
        .padding(2)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.15), lineWidth: 0.8)
        }
        .shadow(color: Color.black.opacity(0.055), radius: 5, y: 1)
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("History range")
    }

    private func shortLabel(for range: MonitoringRange) -> String {
        switch range {
        case .oneHour: return "1h"
        case .sixHours: return "6h"
        case .twelveHours: return "12h"
        case .twentyFourHours: return "24h"
        }
    }
}

private struct GlassySecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.medium))
            .foregroundStyle(.primary.opacity(configuration.isPressed ? 0.72 : 0.92))
            .padding(.horizontal, 9)
            .frame(height: 27)
            .background(
                .thinMaterial,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.075 : 0.045))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(configuration.isPressed ? 0.22 : 0.14), lineWidth: 0.8)
            }
            .shadow(color: Color.black.opacity(0.055), radius: 5, y: 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }
}

struct ActiveUseSummaryLabel: View {
    let duration: TimeInterval?

    var body: some View {
        if let duration {
            Label(
                Formatters.activeUseToday(duration),
                systemImage: "person.fill"
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .help("Observed non-idle use since the start of today. This is not a focus, attention, or productivity score.")
            .accessibilityHint("Observed non-idle use. This is not a focus or productivity score.")
        }
    }
}
