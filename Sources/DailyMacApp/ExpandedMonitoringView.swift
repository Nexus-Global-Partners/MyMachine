import AppKit
import DailyMacCore
import SwiftUI

struct ExpandedMonitoringView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showsWindowDetails = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            Group {
                if let snapshot = model.monitoringSnapshot, snapshot.sampleCount > 0 {
                    GeometryReader { geometry in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 18) {
                                MonitoringTimelineView(
                                    snapshot: snapshot,
                                    samples: model.monitoringSamples,
                                    backgroundPoints: model.monitoringBackgroundPoints,
                                    events: model.monitoringEvents,
                                    presentation: .expanded,
                                    expandedProcessorHeight: geometry.size.height - 390
                                )
                                .equatable()

                                NetworkThroughputGraph(
                                    samples: model.monitoringSamples,
                                    interval: snapshot.interval,
                                    presentation: .expanded
                                )
                                .equatable()
                                .frame(minHeight: 170)

                                windowDetails(snapshot)
                            }
                            .padding(24)
                        }
                    }
                } else {
                    ContentUnavailableView {
                        Label("Preparing the timeline", systemImage: "chart.xyaxis.line")
                    } description: {
                        Text("MY MACHINE will show the expanded history as soon as a complete reading is available.")
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task { model.refreshMonitoringIfNeeded() }
    }

    private var header: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Machine timeline")
                    .font(.title2.weight(.semibold))
                HStack(spacing: 5) {
                    Text(model.monitoringRange == .oneHour
                        ? "Last hour"
                        : "Last \(model.monitoringRange.label.lowercased())")
                    if let dataThrough = model.monitoringDataThrough {
                        Text("·")
                        Text("Data through \(dataThrough.formatted(date: .omitted, time: .shortened))")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            Picker("Time range", selection: Binding(
                get: { model.monitoringRange },
                set: { model.selectMonitoringRange($0) }
            )) {
                Text("1 hr").tag(MonitoringRange.oneHour)
                Text("6 hr").tag(MonitoringRange.sixHours)
                Text("24 hr").tag(MonitoringRange.twentyFourHours)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 220)

            Button {
                model.refreshNow()
            } label: {
                if model.monitoringIsRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .help("Refresh monitoring")
            .accessibilityLabel("Refresh monitoring")
            .disabled(model.monitoringIsRefreshing)

            Button {
                NSApp.keyWindow?.toggleFullScreen(nil)
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("f", modifiers: [.command, .control])
            .help("Enter or exit full screen")
            .accessibilityLabel("Enter or exit full screen")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(.bar)
    }

    private func windowDetails(_ snapshot: MonitoringSnapshot) -> some View {
        DisclosureGroup("What this window means", isExpanded: $showsWindowDetails) {
            let usage = TimelineSemantics.windowUsageSummary(
                from: model.monitoringSamples,
                within: snapshot.interval
            )
            VStack(alignment: .leading, spacing: 12) {
                interpretedDetail(
                    title: "Recorded history",
                    value: Formatters.duration(snapshot.observedDuration),
                    explanation: "Only measured time is summarized; blank spans remain unknown."
                )
                interpretedDetail(
                    title: "Hands-on use",
                    value: usage.handsOnShare.map { Formatters.percent($0 * 100) } ?? "Still measuring",
                    explanation: "Share of recorded input time with typing, pointer, click, or scroll activity—not a focus score."
                )
                interpretedDetail(
                    title: "Longest demanding stretch",
                    value: usage.longestHeavyProcessorRun >= 60
                        ? Formatters.duration(usage.longestHeavyProcessorRun)
                        : "No sustained stretch",
                    explanation: "Continuous time when CPU or estimated GPU demand was high enough to matter for warmth, battery, or headroom."
                )
            }
            .padding(.top, 10)
        }
        .font(.callout)
    }

    private func interpretedDetail(
        title: String,
        value: String,
        explanation: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .fontWeight(.semibold)
                Spacer()
                Text(value)
                    .foregroundStyle(.secondary)
            }
            Text(explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
