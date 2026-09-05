import DailyMacCore
import SwiftUI

struct PreferencesView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system.rawValue
    @State private var confirmErase = false

    var body: some View {
        ScrollView {
            Form {
                Section("Appearance") {
                    Picker("Look", selection: $appearance) {
                        ForEach(AppAppearance.allCases) { option in
                            Label(option.label, systemImage: option.symbol)
                                .tag(option.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text("System follows your Mac. Light and Dark apply consistently to the menu and main window.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Monitoring") {
                    Toggle("Collect activity and performance locally", isOn: Binding(
                        get: { model.settings.hasCollectionConsent && !model.settings.isPaused && model.settings.pauseUntil == nil },
                        set: { $0 ? model.startMonitoring() : model.pauseIndefinitely() }
                    ))
                    Text(model.collectionState.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("Launch at login", isOn: Binding(
                        get: { model.loginItemEnabled },
                        set: { model.setLaunchAtLogin($0) }
                    ))
                    if model.loginItemNeedsApproval {
                        Text("macOS requires approval in Login Items. Monitoring still works whenever MY MACHINE is open, and the app will not repeatedly prompt or install a hidden helper.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("Launch at Login starts MY MACHINE quietly after sign-in. If it quits unexpectedly, its saved data remains safe, but macOS will not relaunch this main-app build until the next login or a manual reopen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("Active sampling detail", selection: settingBinding(\.baseSamplingInterval)) {
                        Text("Balanced — every 15 seconds").tag(TimeInterval(15))
                        Text("Lower overhead — every 30 seconds").tag(TimeInterval(30))
                        Text("Minimal — every 60 seconds").tag(TimeInterval(60))
                    }
                    Text("MY MACHINE automatically slows further while idle, in Low Power Mode, or if its own CPU use rises. Process comparisons run less often than system readings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("Count as idle after", selection: settingBinding(\.idleThreshold)) {
                        Text("2 minutes").tag(TimeInterval(120))
                        Text("5 minutes").tag(TimeInterval(300))
                        Text("10 minutes").tag(TimeInterval(600))
                    }
                }

                Section("Proactive briefings") {
                    Toggle("Tell me when a private briefing is ready", isOn: Binding(
                        get: { model.settings.briefingNotificationsEnabled == true },
                        set: { model.setBriefingNotifications($0) }
                    ))
                    Label(
                        model.notificationDeliveryEnabled ? "Notification delivery is on" : "Notification delivery is not active",
                        systemImage: model.notificationDeliveryEnabled ? "bell.badge.fill" : "bell.slash"
                    )
                    Text(model.notificationStatusDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("The notification itself says only that a private briefing is ready. Practical findings remain inside MY MACHINE so app names and machine details are not exposed on the lock screen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if model.notificationNeedsApproval {
                        Button("Open Notification Settings") { model.openNotificationSettings() }
                    }
                }

                Section("Diagnose My Machine") {
                    Picker("After copying the brief", selection: diagnosisDestinationBinding) {
                        ForEach(DiagnosisDestination.allCases) { destination in
                            Text(destination.label).tag(destination)
                        }
                    }

                    Toggle("Include application names", isOn: diagnosisApplicationNamesBinding)
                    Text("Creates a private 24-hour summary and copies it. It can open ChatGPT or Claude, but never pastes or sends anything.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Application names are hidden by default. Clipboard managers may retain copies; aliases do not make the brief anonymous.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Privacy") {
                    Label("All telemetry and reports stay on this Mac", systemImage: "lock.shield")
                    Text("Collected: timestamps, foreground app identity, elapsed idle time, interval totals for keyboard actions, pointer movement, clicks and scrolling, app lifecycle, sleep/wake, aggregate machine counters, and best-effort app/process names, owner relationships, and resource rollups. Related background helpers and workers can be shown together under their app.")
                        .foregroundStyle(.secondary)
                    Text("Never collected: what you type, individual keys, pointer coordinates or targets, input-event contents, screen pixels, screenshots, window titles, URLs, workspace or project names, prompts, document or file contents, messages, clipboard, file paths, command-line arguments, environment variables, network destinations, credentials, or audio.")
                        .foregroundStyle(.secondary)
                    Text("App-family memory can include shared pages. Its observed file/disk activity is not storage consumed, a list of changed files, or an estimate of SSD wear.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Core monitoring requests no Accessibility, Screen Recording, Input Monitoring, Full Disk Access, Network Extension, or administrator permission. Optional report-ready alerts use only macOS notification permission. MY MACHINE has no analytics service and makes no network request of its own.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Retention") {
                    Picker("Detailed samples", selection: settingBinding(\.rawRetentionDays)) {
                        Text("3 days (recommended)").tag(3)
                        Text("7 days").tag(7)
                        Text("14 days").tag(14)
                    }
                    Picker("Named application history", selection: Binding(
                        get: { model.settings.effectiveNamedHistoryRetentionDays },
                        set: { model.settings.namedHistoryRetentionDays = $0; model.persistSettings() }
                    )) {
                        Text("7 days").tag(7)
                        Text("30 days (recommended)").tag(30)
                        Text("90 days").tag(90)
                    }
                    Picker("Other events", selection: settingBinding(\.eventRetentionDays)) {
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                    }
                    Picker("Aggregate daily trends", selection: settingBinding(\.reportRetentionDays)) {
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                        Text("1 year").tag(365)
                    }
                    Text("Cleanup runs while MY MACHINE is open and on startup. Named reports default to 30 days; older reports keep aggregate trends without application details or original narrative.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Metric availability") {
                    ForEach(MetricCatalog.disclosures) { disclosure in
                        DisclosureGroup {
                            Text(disclosure.technicalDetail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(disclosure.metric) · \(disclosure.origin.rawValue)")
                                Text(disclosure.plainLanguage)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Local data") {
                    LabeledContent("Storage used", value: Formatters.bytes(model.databaseSize))
                    Text(model.dataDirectoryURL.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    HStack {
                        Button("Show Data Folder") { model.revealDataFolder() }
                        Button("Export Current Daily Report") { model.exportToday() }
                            .disabled(model.todayReport == nil)
                    }
                    Button("Delete All Collected Data", role: .destructive) { confirmErase = true }
                }

                Section("Completely remove MY MACHINE") {
                    Text("First turn off Launch at Login above, then quit the app and move MY MACHINE.app to the Trash. To remove its history and preferences too, delete the data folder shown above and ~/Library/Preferences/local.mymachine.app.plist. MY MACHINE installs no daemon, system extension, privileged helper, kernel component, or configuration profile.")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: 820)
            .padding(18)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle("Settings")
        .alert("Delete all collected data?", isPresented: $confirmErase) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) { model.eraseAllData() }
        } message: {
            Text("This removes detailed samples, events, and daily reports. Monitoring, privacy, and launch preferences remain. Separate backups, snapshots, exported reports and clipboard-manager copies are not removed. Monitoring can collect new data afterward.")
        }
    }

    private func settingBinding<T>(_ keyPath: WritableKeyPath<MonitoringSettings, T>) -> Binding<T> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: {
                model.settings[keyPath: keyPath] = $0
                model.persistSettings()
            }
        )
    }

    private var diagnosisDestinationBinding: Binding<DiagnosisDestination> {
        Binding(
            get: { model.settings.diagnosisDestination ?? .copyOnly },
            set: {
                model.settings.diagnosisDestination = $0
                model.persistSettings()
            }
        )
    }

    private var diagnosisApplicationNamesBinding: Binding<Bool> {
        Binding(
            get: { model.settings.includesDiagnosisApplicationNames },
            set: {
                model.settings.diagnosisIncludeApplicationNames = $0
                model.persistSettings()
            }
        )
    }
}
