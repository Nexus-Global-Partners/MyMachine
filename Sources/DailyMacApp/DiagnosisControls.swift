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
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(model.diagnosisState.isPreparing)
        .help(model.diagnosisState.detail)
        .accessibilityHint(model.diagnosisState.detail)
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
