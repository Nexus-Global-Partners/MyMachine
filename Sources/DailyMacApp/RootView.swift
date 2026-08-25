import DailyMacCore
import SwiftUI

enum SidebarDestination: String, CaseIterable, Identifiable {
    case monitoring = "Monitoring"
    case history = "History"
    case activity = "Processes & Activity"
    case settings = "Settings"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .monitoring: return "chart.xyaxis.line"
        case .history: return "calendar"
        case .activity: return "waveform.path.ecg"
        case .settings: return "gearshape"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var route = AppRoute.shared
    @State private var selection: SidebarDestination? = .monitoring

    var body: some View {
        NavigationSplitView {
            List(SidebarDestination.allCases, selection: $selection) { destination in
                Label(destination.rawValue, systemImage: destination.symbol)
                    .tag(destination)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 250)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 8) {
                    Image(systemName: model.collectionState.symbol)
                        .foregroundStyle(statusColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.collectionState.label)
                            .font(.caption.weight(.medium))
                        Text("Local only")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(12)
                .background(.bar)
            }
        } detail: {
            switch selection ?? .monitoring {
            case .monitoring: MonitoringView()
            case .history: HistoryView()
            case .activity: ActivityView()
            case .settings: PreferencesView()
            }
        }
        .alert("MY MACHINE", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onChange(of: route.monitoringRequestGeneration) {
            selection = .monitoring
        }
    }

    private var statusColor: Color {
        switch model.collectionState {
        case .monitoring: return .accentColor
        case .failed: return .red
        default: return .secondary
        }
    }
}

struct PageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.title2.weight(.semibold))
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ReportSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            content
        }
        .frame(maxWidth: 760, alignment: .leading)
    }
}

struct InsightRow: View {
    let insight: ReportInsight

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: symbol)
                    .font(.caption)
                    .foregroundStyle(color)
                    .accessibilityHidden(true)
                Text(insight.title)
                    .font(.subheadline.weight(.semibold))
            }
            Text(insight.explanation)
                .font(.body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            if let evidence = insight.evidence {
                DisclosureGroup("Why this conclusion appears") {
                    Text(evidence)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private var symbol: String {
        switch insight.kind {
        case .observation: return "circle.fill"
        case .efficient: return "checkmark.circle"
        case .caution: return "exclamationmark.circle"
        case .recommendation: return "arrow.right.circle"
        }
    }

    private var color: Color {
        switch insight.kind {
        case .caution: return .orange
        default: return .secondary
        }
    }
}

struct ExplainedMetric: View {
    let title: String
    let interpretation: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(interpretation)
                .textSelection(.enabled)
            DisclosureGroup("Exact reading and method") {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.top, 4)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

extension Date {
    var dailyMacDayTitle: String {
        formatted(.dateTime.weekday(.wide).month(.wide).day().year())
    }
}
