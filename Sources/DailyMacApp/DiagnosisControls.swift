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
                        .foregroundStyle(range == selection ? Color.primary : Color.secondary)
                        .frame(width: itemWidth, height: 23)
                        .background {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(range == selection ? Color.primary.opacity(0.085) : .clear)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(range.label)
                .accessibilityAddTraits(range == selection ? .isSelected : [])
            }
        }
        .padding(2)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.7)
        }
        .shadow(color: Color.black.opacity(0.035), radius: 4, y: 1)
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
            .foregroundStyle(.primary.opacity(configuration.isPressed ? 0.62 : 0.82))
            .padding(.horizontal, 9)
            .frame(height: 27)
            .background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(configuration.isPressed ? 0.13 : 0.07), lineWidth: 0.7)
            }
            .shadow(color: Color.black.opacity(0.03), radius: 4, y: 1)
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
