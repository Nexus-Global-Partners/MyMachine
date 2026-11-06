import AppKit
import Charts
import SwiftUI

@main
@MainActor
struct MyMachineStoreApp: App {
    @StateObject private var monitor = StoreMonitor()

    var body: some Scene {
        Window("MyMachine", id: "dashboard") {
            StoreDashboard(monitor: monitor)
        }
        .defaultSize(width: 510, height: 520)
        .windowResizability(.contentSize)

        MenuBarExtra {
            StoreDashboard(monitor: monitor)
        } label: {
            Label("MyMachine. \(monitor.state.title)",
                  systemImage: monitor.state == .recording ? "record.circle.fill" : "waveform.path")
        }
        .menuBarExtraStyle(.window)
    }
}

private struct StoreDashboard: View {
    @ObservedObject var monitor: StoreMonitor
    @Environment(\.scenePhase) private var scenePhase
    @State private var showPrivacy = false
    @State private var confirmErase = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("MyMachine").font(.title2.weight(.semibold))
                Spacer()
                Label(monitor.state.title, systemImage: monitor.state == .recording ? "record.circle.fill" : "circle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(monitor.state == .recording ? Color.red : Color.secondary)
                    .accessibilityAddTraits(.updatesFrequently)
            }

            if monitor.state == .ready && monitor.readings.isEmpty {
                Text("Start recording CPU, memory, battery, and thermal pressure to a private history on this Mac.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                reading("CPU", value: percent(monitor.latest?.cpuPercent))
                reading("Memory", value: monitor.latest?.memoryUsed.map {
                    ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .memory)
                } ?? "Unavailable")
                reading("Battery", value: percent(monitor.latest?.batteryPercent),
                        detail: monitor.latest?.isCharging == true ? "Charging" : nil)
                reading("Thermal", value: monitor.latest.map { thermalLabel($0.thermal) } ?? "Unavailable")
            }
            if let latest = monitor.latest {
                Text("Last sample \(latest.timestamp.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            StoreChart(readings: monitor.readings, sleep: monitor.sleepSpans)

            if let message = monitor.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                if monitor.state == .ready {
                    Button("Start Monitoring") { monitor.startMonitoring() }
                        .buttonStyle(.borderedProminent)
                } else if monitor.state == .recording || monitor.state == .sleeping {
                    Button("Pause Monitoring") { monitor.pauseMonitoring() }
                }
                Spacer()
                Menu("Options") {
                    Button("Export History…") { monitor.exportHistory() }.disabled(!monitor.canExport)
                    Button("Delete Local History…", role: .destructive) { confirmErase = true }
                        .disabled(!monitor.canErase)
                    Divider()
                    Toggle("Launch at Login", isOn: Binding(
                        get: { monitor.loginStatus == .enabled || monitor.loginStatus == .requiresApproval },
                        set: { monitor.setLaunchAtLogin($0) }
                    ))
                    if monitor.loginStatus == .requiresApproval {
                        Text("Finish enabling in System Settings → Login Items.")
                    }
                    Button("Privacy and License") { showPrivacy = true }
                    if let supportURL = StoreLinks.support {
                        Link("Support", destination: supportURL)
                    }
                    Divider()
                    Button("Quit MyMachine") { NSApp.terminate(nil) }
                        .disabled(monitor.state == .erasing)
                }
                .fixedSize()
            }
        }
        .padding(18)
        .frame(minWidth: 490, idealWidth: 510)
        .task { await monitor.prepare() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { monitor.refreshLoginStatus() }
        }
        .sheet(isPresented: $showPrivacy) { StorePrivacyView() }
        .alert("Delete local history?", isPresented: $confirmErase) {
            Button("Cancel", role: .cancel) {}
            Button("Delete History", role: .destructive) {
                Task { await monitor.eraseHistory() }
            }
        } message: {
            Text("Monitoring pauses and saved readings are removed from this app. Exported files stay where you saved them.")
        }
    }

    private func reading(_ title: String, value: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Text(value).font(.system(.body, design: .monospaced).weight(.medium))
                .lineLimit(1).minimumScaleFactor(0.7)
            if let detail { Text(detail).font(.caption2).foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .combine)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    private func percent(_ value: Double?) -> String {
        guard let value else { return "Unavailable" }
        return (value / 100).formatted(.percent.precision(.fractionLength(0)))
    }
}

private struct StoreChart: View {
    private enum Metric: String, CaseIterable {
        case cpu = "CPU", memory = "Memory", battery = "Battery", thermal = "Thermal"

        func value(in reading: StoreReading) -> Double? {
            switch self {
            case .cpu:
                return reading.cpuPercent
            case .memory:
                guard let used = reading.memoryUsed, let total = reading.memoryTotal, total > 0 else { return nil }
                return Double(used) / Double(total) * 100
            case .battery:
                return reading.batteryPercent
            case .thermal:
                switch reading.thermal {
                case .nominal: return 0
                case .fair: return 1
                case .serious: return 2
                case .critical: return 3
                case .unknown: return nil
                }
            }
        }
    }

    let readings: [StoreReading]
    let sleep: [StoreSleepSpan]
    @State private var metric: Metric = .cpu
    @State private var hours = 1

    var body: some View {
        let now = Date()
        let start = now.addingTimeInterval(-TimeInterval(hours) * 3_600)
        let observations = readings.filter { $0.timestamp >= start && $0.timestamp <= now }
        let spans = sleep.filter { $0.end >= start && $0.start <= now }
        let maximum: Double = metric == .thermal ? 3 : 100

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Reading", selection: $metric) {
                    ForEach(Metric.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                Spacer()
                Picker("History range", selection: $hours) {
                    Text("1 hour").tag(1)
                    Text("6 hours").tag(6)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
            if observations.contains(where: { metric.value(in: $0) != nil }) || !spans.isEmpty {
                Chart {
                    ForEach(spans) { span in
                        RectangleMark(
                            xStart: .value("Sleep start", max(start, span.start)),
                            xEnd: .value("Wake", min(now, span.end)),
                            yStart: .value("Minimum", 0.0),
                            yEnd: .value("Maximum", maximum)
                        )
                        .foregroundStyle(Color.secondary.opacity(0.17))
                        .accessibilityLabel("Observed sleep")
                    }
                    ForEach(observations) { reading in
                        if let value = metric.value(in: reading) {
                            PointMark(x: .value("Time", reading.timestamp), y: .value(metric.rawValue, value))
                                .foregroundStyle(Color.accentColor)
                                .symbolSize(11)
                        }
                    }
                }
                .chartXScale(domain: start...now)
                .chartYScale(domain: 0...maximum)
                .chartYAxis {
                    if metric == .thermal {
                        AxisMarks(values: [0.0, 1.0, 2.0, 3.0]) { mark in
                            AxisGridLine()
                            if let value = mark.as(Double.self) {
                                AxisValueLabel { Text(["Nominal", "Fair", "Serious", "Critical"][Int(value)]) }
                            }
                        }
                    } else {
                        AxisMarks(values: [0.0, 50.0, 100.0]) { mark in
                            AxisGridLine()
                            if let value = mark.as(Double.self) {
                                AxisValueLabel { Text("\(Int(value))%") }
                            }
                        }
                    }
                }
                .frame(height: 165)
            } else {
                ContentUnavailableView(
                    "No \(metric.rawValue) history yet", systemImage: "chart.xyaxis.line",
                    description: Text("Recorded readings appear here when available.")
                )
                .frame(height: 165)
            }
            Text("Gray bands show observed sleep. Gaps mark periods without readings.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private func thermalLabel(_ level: ThermalLevel) -> String {
    level == .unknown ? "Unavailable" : level.rawValue.capitalized
}

private enum StoreLinks {
    static let privacy = httpsURL(for: "MyMachinePrivacyURL")
    static let support = httpsURL(for: "MyMachineSupportURL")

    private static func httpsURL(for key: String) -> URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              let url = URL(string: raw), url.scheme == "https", url.host != nil else { return nil }
        return url
    }
}

private struct StorePrivacyView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Privacy and License").font(.title2.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(resource("StorePrivacy", extension: "txt")).textSelection(.enabled)
                    if let url = StoreLinks.privacy { Link("Open the privacy policy", destination: url) }
                    Text("Open Source License").font(.headline)
                    Text(resource("LICENSE", extension: nil)).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(18)
        .frame(width: 470, height: 380)
    }

    private func resource(_ name: String, extension fileExtension: String?) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: fileExtension),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return "This document could not be opened."
        }
        return contents
    }
}
