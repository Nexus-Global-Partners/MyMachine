import Foundation

public struct InsightEngine: Sendable {
    public init() {}

    public func makeReport(
        dayKey: String,
        timezone: TimeZone,
        samples: [SystemSample],
        processSamples: [ProcessSample],
        events: [ActivityEvent],
        historicalReports: [DailyReport] = []
    ) -> DailyReport {
        let ordered = samples.sorted { $0.timestamp < $1.timestamp }
        let longestContinuousCoverage = CoverageEvaluator.longestContinuousDuration(in: ordered)
        let supportsNarrative = longestContinuousCoverage >= CoverageEvaluator.narrativeMinimum
        let active = ordered.filter { !$0.isIdle }
        let activeDuration = active.reduce(0) { $0 + boundedDuration($1) }
        let idleDuration = ordered.filter(\.isIdle).reduce(0) { $0 + boundedDuration($1) }
        let averageCPU = weightedAverage(ordered, value: \SystemSample.cpuPercent)
        let peakCPU = ordered.map(\.cpuPercent).max() ?? 0
        let averageMemory = UInt64(max(0, weightedAverage(ordered) { Double($0.memoryUsedBytes) }))
        let peakMemory = ordered.map(\.memoryUsedBytes).max() ?? 0
        let endingSwap = ordered.last?.swapUsedBytes ?? 0
        let memoryTotal = ordered.last?.memoryTotalBytes
        let totalDisk = ordered.reduce(UInt64(0)) { $0 &+ $1.diskReadBytes &+ $1.diskWriteBytes }
        let totalNetwork = ordered.reduce(UInt64(0)) { $0 &+ $1.networkReceivedBytes &+ $1.networkSentBytes }
        let thermalPeak = peakThermal(ordered.map(\.thermalLevel))
        let pressurePeak: MemoryPressureLevel = ordered.contains(where: { $0.memoryPressure == .high }) ? .high : (ordered.contains(where: { $0.memoryPressure == .elevated }) ? .elevated : .low)
        let observedActivations = events.filter { $0.type == .foregroundChanged }.count
        let switches = observedActivations > 0 ? observedActivations : contextSwitchCount(active)
        let apps = summarizeApps(active)
        let categories = summarizeCategories(active)
        let batteryChange = meaningfulBatteryChange(ordered)
        let important = supportsNarrative ? importantMoments(samples: ordered, events: events) : []
        let correlations = supportsNarrative ? makeCorrelations(samples: active, processes: processSamples, categories: categories, apps: apps, history: historicalReports) : []
        let recommendations = supportsNarrative ? makeRecommendations(samples: ordered, processes: processSamples, batteryChange: batteryChange, thermalPeak: thermalPeak) : []
        let headline = supportsNarrative
            ? makeHeadline(activeDuration: activeDuration, apps: apps, categories: categories, averageCPU: averageCPU, memoryPressure: pressurePeak, thermalPeak: thermalPeak)
            : "Not enough continuous coverage for a reliable briefing"
        let overview = supportsNarrative
            ? makeOverview(activeDuration: activeDuration, idleDuration: idleDuration, switches: switches, apps: apps, categories: categories, averageCPU: averageCPU, samples: ordered)
            : "MY MACHINE recorded some readings, but no uninterrupted stretch reached about two minutes. Short fragments and counter baselines are kept as visible gaps rather than turned into performance conclusions."

        var limitations: [String] = []
        if ordered.isEmpty {
            limitations.append("There was not enough recorded activity to describe this day.")
        } else if !supportsNarrative {
            limitations.append("No uninterrupted recorded stretch reached about two minutes, so this report does not interpret performance or suggest changes.")
        }
        limitations.append("Work categories are local estimates based only on application identity, not window titles or content.")
        limitations.append("Report days follow the Mac’s current local timezone. If the timezone changes while detailed samples are retained, some activity near an adjacent day boundary can move between day reports.")
        if ordered.contains(where: { $0.gpuPercent != nil }) {
            limitations.append("GPU activity is an optional aggregate hardware estimate reported by the current graphics driver. It is not guaranteed, is not per-app attribution, and contains no screen or displayed-content data.")
        } else {
            limitations.append("The current graphics driver did not expose a usable aggregate GPU activity estimate for these readings, so no GPU value was inferred.")
        }
        limitations.append("Fan speed and exact sensor temperatures are not claimed because macOS offers no stable supported interface for them here.")
        if processSamples.isEmpty && !ordered.isEmpty {
            limitations.append("Process attribution was unavailable for these samples, so causes are described at the application level only.")
        } else if !processSamples.isEmpty {
            limitations.append("Process attribution is best-effort and incomplete for protected or short-lived processes; named processes are the largest observed contributors, not a complete accounting.")
        }

        return DailyReport(
            dayKey: dayKey,
            generatedAt: Date(),
            timezoneIdentifier: timezone.identifier,
            headline: headline,
            overview: overview,
            activeDuration: activeDuration,
            idleDuration: idleDuration,
            contextSwitches: switches,
            averageCPU: averageCPU,
            peakCPU: peakCPU,
            averageMemoryBytes: averageMemory,
            peakMemoryBytes: peakMemory,
            endingSwapBytes: endingSwap,
            memoryTotalBytes: memoryTotal,
            peakMemoryPressure: pressurePeak,
            totalDiskBytes: totalDisk,
            totalNetworkBytes: totalNetwork,
            batteryChangePercent: batteryChange,
            thermalPeak: thermalPeak,
            applications: apps,
            categories: categories,
            importantMoments: important,
            correlations: correlations,
            recommendations: recommendations,
            limitations: limitations,
            sampleCount: ordered.count,
            longestContinuousCoverage: longestContinuousCoverage
        )
    }

    public func makeMonitoringSnapshot(
        range: MonitoringRange,
        endingAt end: Date = Date(),
        samples: [SystemSample],
        appResourceSamples: [AppResourceSample] = []
    ) -> MonitoringSnapshot {
        let interval = range.interval(endingAt: end)
        let segmented = segmentedWindowedSamples(samples, within: interval)
        let windowed = segmented.map(\.value)
        let ordered = windowed.map(\.sample)
        let active = windowed.filter { !$0.sample.isIdle }
        let idle = windowed.filter { $0.sample.isIdle }
        let observedDuration = min(interval.duration, windowed.reduce(0) { $0 + $1.duration })
        let activeDuration = active.reduce(0) { $0 + $1.duration }
        let idleDuration = idle.reduce(0) { $0 + $1.duration }
        let averageCPU = weightedWindowAverage(windowed) { $0.cpuPercent }
        let peakCPU = ordered.map(\.cpuPercent).max() ?? 0
        let averageMemory = UInt64(max(0, weightedWindowAverage(windowed) { Double($0.memoryUsedBytes) }))
        let peakMemory = ordered.map(\.memoryUsedBytes).max() ?? 0
        let memoryTotal = ordered.last?.memoryTotalBytes
        let peakPressure = peakMemoryPressure(ordered.map(\.memoryPressure))
        let elevatedMemoryDuration = windowed
            .filter { $0.sample.memoryPressure != .low }
            .reduce(0) { $0 + $1.duration }
        let endingSwap = ordered.last?.swapUsedBytes ?? 0
        let swapChange = meaningfulSwapChange(segmented, within: interval)
        let totalDisk = proportionalCounterTotal(windowed) { $0.diskReadBytes &+ $0.diskWriteBytes }
        let totalNetwork = proportionalCounterTotal(windowed) { $0.networkReceivedBytes &+ $0.networkSentBytes }
        let thermalPeak = peakThermal(ordered.map(\.thermalLevel))
        let batteryChange = meaningfulBatteryChange(ordered)
        let applications = summarizeMonitoringApps(active)
        let categories = summarizeMonitoringCategories(active)
        let switches = monitoringContextSwitchCount(segmented)
        let longestCoverage = CoverageEvaluator.longestContinuousDuration(in: samples, within: interval)
        let supportsNarrative = longestCoverage >= CoverageEvaluator.narrativeMinimum
        let backgroundApplications = makeBackgroundAppSummaries(
            samples: appResourceSamples,
            systemSamples: samples,
            in: interval
        )
        let insights = monitoringInsights(
            range: range,
            supportsNarrative: supportsNarrative,
            segmented: segmented,
            observedDuration: observedDuration,
            activeDuration: activeDuration,
            averageCPU: averageCPU,
            peakMemoryPressure: peakPressure,
            elevatedMemoryDuration: elevatedMemoryDuration,
            thermalPeak: thermalPeak,
            swapChangeBytes: swapChange,
            contextSwitches: switches,
            applications: applications
        )

        return MonitoringSnapshot(
            range: range,
            interval: interval,
            generatedAt: end,
            sampleCount: windowed.count,
            observedDuration: observedDuration,
            longestContinuousCoverage: longestCoverage,
            activeDuration: activeDuration,
            idleDuration: idleDuration,
            averageCPU: averageCPU,
            peakCPU: peakCPU,
            averageMemoryBytes: averageMemory,
            peakMemoryBytes: peakMemory,
            memoryTotalBytes: memoryTotal,
            peakMemoryPressure: peakPressure,
            elevatedMemoryDuration: elevatedMemoryDuration,
            endingSwapBytes: endingSwap,
            swapChangeBytes: swapChange,
            totalDiskBytes: totalDisk,
            totalNetworkBytes: totalNetwork,
            thermalPeak: thermalPeak,
            batteryChangePercent: batteryChange,
            contextSwitches: switches,
            applications: applications,
            categories: categories,
            insights: insights,
            backgroundApplications: backgroundApplications
        )
    }

    public func makeMonitoringChartPoints(
        samples: [SystemSample],
        in interval: DateInterval,
        limit: Int = 720
    ) -> [MonitoringChartPoint] {
        let segmented = segmentedWindowedSamples(samples, within: interval)
        guard !segmented.isEmpty, limit > 0 else { return [] }
        let selected = downsampleMonitoringPoints(segmented, interval: interval, limit: limit)
        return selected.map { item in
            let sample = item.value.sample
            return MonitoringChartPoint(
                id: sample.id,
                timestamp: sample.timestamp,
                cpuPercent: sample.cpuPercent,
                gpuPercent: sample.gpuPercent,
                memoryUsedBytes: sample.memoryUsedBytes,
                memoryTotalBytes: sample.memoryTotalBytes,
                memoryPressure: sample.memoryPressure,
                swapUsedBytes: sample.swapUsedBytes,
                diskReadBytes: sample.diskReadBytes,
                diskWriteBytes: sample.diskWriteBytes,
                networkReceivedBytes: sample.networkReceivedBytes,
                networkSentBytes: sample.networkSentBytes,
                batteryPercent: sample.batteryPercent,
                powerSource: sample.powerSource,
                thermalLevel: sample.thermalLevel,
                foregroundApp: sample.foregroundApp,
                category: sample.category,
                isIdle: sample.isIdle,
                duration: item.value.duration,
                segment: item.segment,
                manualActivity: sample.manualActivity
            )
        }
    }

    public func makeBackgroundAppSummaries(
        samples: [AppResourceSample],
        systemSamples: [SystemSample] = [],
        in interval: DateInterval
    ) -> [BackgroundAppSummary] {
        let clipped = clippedAppResources(samples, within: interval)
        let pressureIntervals = matchingSystemIntervals(systemSamples, within: interval) {
            $0.memoryPressure != .low
        }
        let thermalIntervals = matchingSystemIntervals(systemSamples, within: interval) {
            $0.thermalLevel == .serious || $0.thermalLevel == .critical
        }
        let groups = Dictionary(grouping: clipped) {
            $0.sample.ownerBundleID ?? $0.sample.ownerName
        }

        return groups.compactMap { _, values -> BackgroundAppSummary? in
            guard let latest = values.max(by: { $0.sample.timestamp < $1.sample.timestamp })?.sample else { return nil }
            let background = values.filter { !$0.sample.isForeground }
            let backgroundDuration = background.reduce(0) { $0 + $1.duration }
            guard backgroundDuration > 0 else { return nil }
            let active = background.filter(isMeasurableBackgroundActivity)
            let activeDuration = active.reduce(0) { $0 + $1.duration }
            let averageCPU = weightedAppAverage(background) { $0.cpuPercent }
            let averageMemory = UInt64(max(0, weightedAppAverage(background) { Double($0.memoryBytes) }))
            let cpuCoreSeconds = background.reduce(0) {
                $0 + max(0, $1.sample.cpuPercent) / 100 * $1.duration
            }
            let diskRead = proportionalAppCounterTotal(background, value: \.diskReadBytes)
            let diskWrite = proportionalAppCounterTotal(background, value: \.diskWriteBytes)
            let pressureOverlap = active.reduce(0) {
                $0 + overlapDuration(of: $1.interval, with: pressureIntervals)
            }
            let thermalOverlap = active.reduce(0) {
                $0 + overlapDuration(of: $1.interval, with: thermalIntervals)
            }
            var workerNames: [String] = []
            for name in background.flatMap({ $0.sample.workerNames }) where !workerNames.contains(name) {
                workerNames.append(name)
                if workerNames.count == 6 { break }
            }
            return BackgroundAppSummary(
                ownerName: latest.ownerName,
                ownerBundleID: latest.ownerBundleID,
                observedDuration: values.reduce(0) { $0 + $1.duration },
                backgroundDuration: backgroundDuration,
                backgroundActivityDuration: activeDuration,
                averageCPUPercent: averageCPU,
                peakCPUPercent: background.map(\.sample.cpuPercent).max() ?? 0,
                cpuCoreSeconds: cpuCoreSeconds,
                averageMemoryBytes: averageMemory,
                peakMemoryBytes: background.map(\.sample.memoryBytes).max() ?? 0,
                diskReadBytes: diskRead,
                diskWriteBytes: diskWrite,
                elevatedMemoryOverlapDuration: min(activeDuration, pressureOverlap),
                seriousThermalOverlapDuration: min(activeDuration, thermalOverlap),
                maximumProcessCount: background.map(\.sample.processCount).max() ?? 0,
                maximumWorkerCount: background.map(\.sample.workerCount).max() ?? 0,
                maximumAgentWorkerCount: background.map(\.sample.agentWorkerCount).max() ?? 0,
                workerNames: workerNames,
                latestTimestamp: latest.timestamp
            )
        }.sorted { lhs, rhs in
            let left = backgroundImpactScore(lhs)
            let right = backgroundImpactScore(rhs)
            return left == right ? lhs.ownerName.localizedCaseInsensitiveCompare(rhs.ownerName) == .orderedAscending : left > right
        }
    }

    public func makeBackgroundActivityPoints(
        samples: [AppResourceSample],
        systemSamples: [SystemSample] = [],
        in interval: DateInterval,
        limit: Int = 1_440
    ) -> [BackgroundActivityPoint] {
        guard limit > 0 else { return [] }
        let pressureIntervals = matchingSystemIntervals(systemSamples, within: interval) {
            $0.memoryPressure != .low
        }
        let thermalIntervals = matchingSystemIntervals(systemSamples, within: interval) {
            $0.thermalLevel == .serious || $0.thermalLevel == .critical
        }
        let all = clippedAppResources(samples, within: interval)
            .filter { !$0.sample.isForeground }
            .map { item in
                BackgroundActivityPoint(
                    id: item.sample.id,
                    timestamp: item.sample.timestamp,
                    duration: item.duration,
                    ownerName: item.sample.ownerName,
                    ownerBundleID: item.sample.ownerBundleID,
                    isForeground: false,
                    cpuPercent: item.sample.cpuPercent,
                    memoryBytes: item.sample.memoryBytes,
                    diskBytes: proportionalBytes(item.sample.diskReadBytes &+ item.sample.diskWriteBytes, fraction: item.fraction),
                    processCount: item.sample.processCount,
                    workerCount: item.sample.workerCount,
                    agentWorkerCount: item.sample.agentWorkerCount,
                    elevatedMemoryOverlap: overlapDuration(of: item.interval, with: pressureIntervals) > 0,
                    seriousThermalOverlap: overlapDuration(of: item.interval, with: thermalIntervals) > 0
                )
            }
            .sorted { $0.timestamp < $1.timestamp }
        guard all.count > limit else { return all }
        return downsampleBackgroundPoints(all, limit: limit)
    }

    public func makeTrend(reports: [DailyReport], days: Int, now: Date = Date(), timezone: TimeZone = .autoupdatingCurrent) -> TrendSummary {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        let start = calendar.startOfDay(for: now)
        let cutoff = calendar.date(byAdding: .day, value: -(max(1, days) - 1), to: start) ?? start
        let cutoffKey = DayBoundaries.key(for: cutoff, timezone: timezone)
        let todayKey = DayBoundaries.key(for: now, timezone: timezone)
        let selected = reports.filter {
            $0.dayKey >= cutoffKey && $0.dayKey <= todayKey && $0.sampleCount >= 20 && $0.activeDuration >= 30 * 60
                && ($0.longestContinuousCoverage ?? 0) >= CoverageEvaluator.narrativeMinimum
        }.sorted { $0.dayKey > $1.dayKey }
        guard !selected.isEmpty else {
            return TrendSummary(days: days, activeDuration: 0, averageDailyCPU: 0, mostUsedCategory: nil, notableChange: nil, narrative: "There is not enough history yet to establish a normal pattern.")
        }
        let activeDuration = selected.reduce(0) { $0 + $1.activeDuration }
        let averageCPU = selected.map(\.averageCPU).reduce(0, +) / Double(selected.count)
        var categoryDurations: [WorkCategory: TimeInterval] = [:]
        selected.flatMap(\.categories).forEach { categoryDurations[$0.category, default: 0] += $0.activeDuration }
        let mostUsed = categoryDurations.max { $0.value < $1.value }?.key
        let coverage = selected.count == 1 ? "one recorded day" : "\(selected.count) recorded days"
        var narrative = "Across \(coverage), MY MACHINE observed \(Formatters.duration(activeDuration)) of active use."
        if let mostUsed {
            narrative += " \(mostUsed.rawValue) was the largest work category, and typical whole-machine CPU use averaged \(Formatters.percent(averageCPU))."
        }
        let change = trendChange(selected)
        if let change { narrative += " \(change)" }
        return TrendSummary(days: days, activeDuration: activeDuration, averageDailyCPU: averageCPU, mostUsedCategory: mostUsed, notableChange: change, narrative: narrative)
    }

    private func makeHeadline(activeDuration: TimeInterval, apps: [AppUsageSummary], categories: [CategorySummary], averageCPU: Double, memoryPressure: MemoryPressureLevel, thermalPeak: ThermalLevel) -> String {
        guard activeDuration >= 60 else { return "Not enough activity has been recorded yet" }
        let mainWork = categories.first?.category.rawValue.lowercased() ?? "mixed work"
        let mainApp = apps.first?.name ?? "several applications"
        if thermalPeak == .serious || thermalPeak == .critical {
            return "A \(mainWork) day led by \(mainApp), with a period of meaningful thermal load"
        }
        if averageCPU >= 60 {
            return "A processor-heavy \(mainWork) day led by \(mainApp)"
        }
        if memoryPressure == .high {
            return "A \(mainWork) day led by \(mainApp), with a period of constrained memory"
        }
        if memoryPressure == .elevated {
            return "A \(mainWork) day led by \(mainApp), with some elevated memory demand"
        }
        return "A \(mainWork) day led by \(mainApp), without a sustained CPU, memory-pressure, or heat concern in the recorded periods"
    }

    private func makeOverview(activeDuration: TimeInterval, idleDuration: TimeInterval, switches: Int, apps: [AppUsageSummary], categories: [CategorySummary], averageCPU: Double, samples: [SystemSample]) -> String {
        guard !samples.isEmpty else {
            return "Monitoring is ready. Once the Mac has been used for a while, this page will explain the app use that was observed, how the machine behaved, and whether anything is worth changing."
        }
        let topApps = apps.prefix(3).map(\.name)
        let appPhrase = naturalList(topApps)
        let mainCategory = categories.first?.category.rawValue.lowercased() ?? "mixed work"
        var text = "MY MACHINE recorded \(Formatters.duration(activeDuration)) of active use, mainly \(mainCategory)"
        if !appPhrase.isEmpty { text += " in \(appPhrase)" }
        text += ". Whole-machine CPU use averaged \(Formatters.percent(averageCPU)). \(PracticalInterpreter.cpu(averageCPU))"
        if idleDuration >= 30 * 60 {
            text += " It also observed \(Formatters.duration(idleDuration)) of idle time, which is excluded from active-use estimates."
        }
        if switches > 0, activeDuration >= 30 * 60 {
            let rate = Double(switches) / max(activeDuration / 3_600, 0.5)
            if rate >= 8, switches >= 6 {
                text += " macOS reported about \(switches) foreground-app changes—roughly \(Int(rate.rounded())) per active hour—so app switching was frequent. This describes app changes, not attention or productivity."
            } else if rate <= 3, activeDuration >= 60 * 60 {
                text += " macOS reported about \(switches) foreground-app changes—roughly \(Int(rate.rounded())) per active hour—so apps tended to remain in front for longer stretches. This does not measure focus."
            } else {
                text += " macOS reported about \(switches) foreground-app changes, or roughly \(Int(rate.rounded())) per active hour."
            }
        }
        return text
    }

    private func summarizeApps(_ samples: [SystemSample]) -> [AppUsageSummary] {
        let groups = Dictionary(grouping: samples) { $0.foregroundBundleID ?? $0.foregroundApp }
        return groups.compactMap { _, values in
            guard let first = values.first else { return nil }
            let duration = values.reduce(0) { $0 + boundedDuration($1) }
            let cpu = weightedAverage(values, value: \SystemSample.cpuPercent)
            let memory = UInt64(max(0, weightedAverage(values) { Double($0.memoryUsedBytes) }))
            let interpretation = "\(first.foregroundApp) was in front for about \(Formatters.duration(duration)). During those intervals, \(PracticalInterpreter.cpu(cpu)) This is whole-machine context, including background work—not attribution to the app alone."
            return AppUsageSummary(name: first.foregroundApp, bundleID: first.foregroundBundleID, activeDuration: duration, averageSystemCPU: cpu, averageMemoryBytes: memory, interpretation: interpretation)
        }.sorted { lhs, rhs in
            if lhs.activeDuration != rhs.activeDuration {
                return lhs.activeDuration > rhs.activeDuration
            }
            let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return (lhs.bundleID ?? "") < (rhs.bundleID ?? "")
        }
    }

    private func summarizeCategories(_ samples: [SystemSample]) -> [CategorySummary] {
        let groups = Dictionary(grouping: samples, by: \SystemSample.category)
        return groups.map { category, values in
            let duration = values.reduce(0) { $0 + boundedDuration($1) }
            let cpu = weightedAverage(values, value: \SystemSample.cpuPercent)
            return CategorySummary(category: category, activeDuration: duration, averageCPU: cpu, interpretation: "\(category.rawValue) accounted for \(Formatters.duration(duration)) of active use. During those intervals, \(PracticalInterpreter.cpu(cpu)) This is whole-machine context, not proof that the foreground app caused the load.")
        }.sorted { lhs, rhs in
            lhs.activeDuration == rhs.activeDuration
                ? lhs.category.rawValue < rhs.category.rawValue
                : lhs.activeDuration > rhs.activeDuration
        }
    }

    private func importantMoments(samples: [SystemSample], events: [ActivityEvent]) -> [ReportInsight] {
        let notableByType = Dictionary(grouping: events.filter { $0.severity >= .notable }, by: \.type)
        let selectedEvents = notableByType.compactMap { _, values in
            values.sorted { lhs, rhs in lhs.severity == rhs.severity ? lhs.timestamp < rhs.timestamp : lhs.severity > rhs.severity }.first
        }.sorted { lhs, rhs in lhs.severity == rhs.severity ? lhs.timestamp < rhs.timestamp : lhs.severity > rhs.severity }
        var insights: [ReportInsight] = selectedEvents
            .prefix(6)
            .map { ReportInsight(kind: $0.severity == .important ? .caution : .observation, title: $0.title, explanation: $0.explanation) }
        let recordedTypes = Set(selectedEvents.prefix(6).map(\.type))

        let highCPU = segments(samples: samples) { $0.cpuPercent >= 75 }
        for segment in highCPU where segment.duration >= 120 && !recordedTypes.contains(.sustainedCPU) {
            let app = mostCommon(segment.samples.map(\.foregroundApp)) ?? "active work"
            let avg = weightedAverage(segment.samples, value: \SystemSample.cpuPercent)
            insights.append(ReportInsight(
                kind: .caution,
                title: "Sustained processor load around \(time(segment.start))",
                explanation: "CPU use stayed near \(Formatters.percent(avg)) for \(Formatters.duration(segment.duration)) while \(app) was mainly in front. This was long enough to increase heat and battery use; it matters more if the Mac also felt less responsive."
            ))
        }

        let pressure = segments(samples: samples) { $0.memoryPressure != .low }
        for segment in pressure where segment.duration >= 300 && !recordedTypes.contains(.memoryPressure) {
            let peakSwap = segment.samples.map(\.swapUsedBytes).max() ?? 0
            insights.append(ReportInsight(
                kind: .caution,
                title: "Memory demand was elevated around \(time(segment.start))",
                explanation: "Memory pressure stayed above its comfortable range for \(Formatters.duration(segment.duration)), with up to \(Formatters.bytes(peakSwap)) of swap allocated. macOS handled it safely, but heavy app switching may have felt slower."
            ))
        }

        if insights.isEmpty, let best = samples.min(by: { $0.cpuPercent < $1.cpuPercent }), samples.count >= 4 {
            insights.append(ReportInsight(kind: .efficient, title: "No recorded CPU, memory-pressure, or heat disruption stood out", explanation: "Those observed signals stayed within comfortable ranges. No action is suggested from them; this conclusion does not use the optional graphics-driver estimate and does not rule out graphics activity, network latency, or a workflow issue unrelated to machine load."))
            _ = best
        }
        return Array(insights.prefix(10))
    }

    private func makeCorrelations(samples: [SystemSample], processes: [ProcessSample], categories: [CategorySummary], apps: [AppUsageSummary], history: [DailyReport]) -> [ReportInsight] {
        var result: [ReportInsight] = []
        let eligible = categories.filter { $0.activeDuration >= 15 * 60 }
        if let expensive = eligible.max(by: { $0.averageCPU < $1.averageCPU }), eligible.count >= 2 {
            let baseline = eligible.filter { $0.category != expensive.category }.map(\.averageCPU).reduce(0, +) / Double(max(1, eligible.count - 1))
            if expensive.averageCPU >= max(35, baseline * 1.35) {
                result.append(ReportInsight(
                    kind: .observation,
                    title: "\(expensive.category.rawValue) was the most processor-demanding work",
                    explanation: "It used about \(Formatters.percent(expensive.averageCPU)) of whole-machine CPU on average, compared with roughly \(Formatters.percent(baseline)) across the other substantial work categories. This helps explain when heat or battery use was most likely to rise.",
                    evidence: "Based on \(Formatters.duration(expensive.activeDuration)) in this category."
                ))
            }
        }

        if let top = apps.first, top.activeDuration >= 20 * 60 {
            result.append(ReportInsight(
                kind: .observation,
                title: "\(top.name) shaped most of the day",
                explanation: "It was the foreground application for \(Formatters.duration(top.activeDuration)). During those periods, whole-machine CPU averaged \(Formatters.percent(top.averageSystemCPU)), so its workflow context—not necessarily the app alone—was the main environment in which the Mac was operating."
            ))
        }

        let background = Dictionary(grouping: processes.filter { !$0.isForeground && $0.cpuPercent >= 50 }, by: \ProcessSample.name)
        let sustainedBackground = background.compactMap { name, values -> (String, Double, Int)? in
            guard values.count >= 4 else { return nil }
            return (name, values.map(\.cpuPercent).reduce(0, +) / Double(values.count), values.count)
        }
        if let noisy = sustainedBackground.filter({ $0.1 >= 100 }).max(by: { $0.1 < $1.1 }) {
            result.append(ReportInsight(
                kind: .caution,
                title: "\(noisy.0) repeatedly kept at least one CPU core-equivalent busy while not frontmost",
                explanation: "Its observed process CPU averaged \(Formatters.percent(noisy.1)) of one core-equivalent across \(noisy.2) significant samples. On a multi-core Mac this is only part of total capacity, but sustained work can still add heat or battery use. It may be entirely expected; this is not proof of waste."
            ))
        }

        let comparableHistory = history.prefix(14).compactMap { report -> Double? in
            guard report.activeDuration >= 30 * 60,
                  (report.longestContinuousCoverage ?? 0) >= CoverageEvaluator.narrativeMinimum,
                  !report.categories.isEmpty else { return nil }
            let total = report.categories.reduce(0) { $0 + $1.activeDuration }
            guard total > 0 else { return nil }
            return report.categories.reduce(0) { $0 + $1.averageCPU * $1.activeDuration } / total
        }
        if comparableHistory.count >= 5, let current = samples.isEmpty ? nil : Optional(weightedAverage(samples, value: \SystemSample.cpuPercent)) {
            let baseline = comparableHistory.reduce(0, +) / Double(comparableHistory.count)
            if current > baseline * 1.4 && current - baseline >= 10 {
                result.append(ReportInsight(kind: .observation, title: "Today was heavier than the recent baseline", explanation: "Active periods averaged \(Formatters.percent(current)) CPU versus about \(Formatters.percent(baseline)) across recent days. This makes today's extra heat or battery use unusual rather than merely normal for this Mac."))
            }
        }

        if result.isEmpty {
            result.append(ReportInsight(kind: .observation, title: "No strong work–machine relationship is established yet", explanation: "MY MACHINE avoids drawing conclusions from short or weak evidence. More active time—or several comparable days—will make workload comparisons meaningful."))
        }
        return result
    }

    private func makeRecommendations(samples: [SystemSample], processes: [ProcessSample], batteryChange: Double?, thermalPeak: ThermalLevel) -> [ReportInsight] {
        guard !samples.isEmpty else { return [] }
        var result: [ReportInsight] = []
        let elevatedDuration = samples.filter { $0.memoryPressure != .low }.reduce(0) { $0 + boundedDuration($1) }
        let swapGrowth = (samples.last?.swapUsedBytes ?? 0) > (samples.first?.swapUsedBytes ?? 0) ? (samples.last!.swapUsedBytes - samples.first!.swapUsedBytes) : 0
        if elevatedDuration >= 30 * 60 && swapGrowth >= 512_000_000 {
            let pressureSamples = samples.filter { $0.memoryPressure != .low }
            let tolerance = max(90, (samples.map(\.samplingInterval).max() ?? 60) * 1.5)
            let overlapping = processes.filter { process in
                hasSample(near: process.timestamp, in: pressureSamples, tolerance: tolerance)
            }
            let memoryProcess = overlapping.filter { $0.bundleID != nil }.max(by: { $0.memoryBytes < $1.memoryBytes })
            let cause = memoryProcess.map { " During those pressure periods, \($0.name) was the largest retained identifiable app sample at \(Formatters.bytes($0.memoryBytes)); that is overlap, not proof of cause." } ?? ""
            result.append(ReportInsight(
                kind: .recommendation,
                title: "Close completed heavy work before the next memory-intensive session",
                explanation: "Memory pressure was elevated for \(Formatters.duration(elevatedDuration)) and swap grew by \(Formatters.bytes(swapGrowth)).\(cause) Quitting a finished heavy app is a targeted way to restore headroom before starting another large workload.",
                evidence: "Recommended only because elevated pressure and meaningful swap growth occurred together."
            ))
        }

        let backgroundGroups = Dictionary(grouping: processes.filter { !$0.isForeground && $0.bundleID != nil }, by: \ProcessSample.name)
        if let candidate = backgroundGroups.map({ name, values -> (String, Double, Int) in
            (name, values.map(\.cpuPercent).reduce(0, +) / Double(values.count), values.count)
        }).filter({ $0.1 >= 100 && $0.2 >= 8 }).max(by: { $0.1 < $1.1 }) {
            result.append(ReportInsight(
                kind: .recommendation,
                title: "Check whether \(candidate.0) still needs to be running after its task",
                explanation: "It repeatedly used about \(Formatters.percent(candidate.1)) of one CPU core-equivalent while not frontmost. If that work was expected, leave it alone; if its task had finished, quitting the app normally could reduce avoidable heat and battery use.",
                evidence: "Seen in \(candidate.2) significant samples; this recommendation is limited to an identifiable application, not a system daemon."
            ))
        }

        if let batteryChange, batteryChange <= -12 {
            let batterySamples = samples.filter { $0.powerSource == .battery }
            let duration = batterySamples.reduce(0) { $0 + boundedDuration($1) }
            if duration >= 60 * 60, let demanding = Dictionary(grouping: batterySamples, by: \SystemSample.category)
                .map({ ($0.key, weightedAverage($0.value, value: \SystemSample.cpuPercent), $0.value.reduce(0) { $0 + boundedDuration($1) }) })
                .filter({ $0.2 >= 20 * 60 })
                .max(by: { $0.1 < $1.1 }) {
                result.append(ReportInsight(
                    kind: .recommendation,
                    title: "Use power for a long \(demanding.0.rawValue.lowercased()) session when convenient",
                    explanation: "Battery fell by about \(Formatters.percent(abs(batteryChange))) across recorded battery use, and \(demanding.0.rawValue.lowercased()) was the most processor-demanding substantial category. Connecting power for a similar long session would protect runtime; short sessions do not need a change.",
                    evidence: "Based on at least an hour of battery readings, not an instantaneous estimate."
                ))
            }
        }

        if thermalPeak == .serious || thermalPeak == .critical {
            let hot = samples.filter { $0.thermalLevel == .serious || $0.thermalLevel == .critical }
            if hot.count >= 2 {
                let category = mostCommon(hot.map(\.category))?.rawValue.lowercased() ?? "the heaviest workload"
                result.append(ReportInsight(
                    kind: .recommendation,
                    title: "Avoid stacking another heavy workload onto the next \(category) session",
                    explanation: "macOS reported serious thermal pressure more than once, meaning heat may have constrained performance. Running large jobs sequentially—or closing completed background work first—is more likely to preserve speed than changing everyday settings.",
                    evidence: "Supported by repeated system thermal-state readings."
                ))
            }
        }

        return Array(result.prefix(3))
    }

    private func meaningfulBatteryChange(_ samples: [SystemSample]) -> Double? {
        var runs: [[SystemSample]] = []
        var current: [SystemSample] = []
        func finish() {
            if !current.isEmpty { runs.append(current) }
            current = []
        }
        for sample in samples {
            let isDischarging = sample.powerSource == .battery && sample.isCharging != true && sample.batteryPercent != nil
            if !isDischarging {
                finish()
                continue
            }
            if let last = current.last,
               sample.timestamp.timeIntervalSince(last.timestamp) > max(sample.samplingInterval, last.samplingInterval) * 3 {
                finish()
            }
            current.append(sample)
        }
        finish()
        let eligible = runs.compactMap { run -> (TimeInterval, Double)? in
            guard let first = run.first, let last = run.last,
                  let start = first.batteryPercent, let end = last.batteryPercent else { return nil }
            let duration = last.timestamp.timeIntervalSince(first.timestamp)
            guard duration >= 20 * 60, end < start else { return nil }
            return (duration, end - start)
        }
        return eligible.max(by: { $0.0 < $1.0 })?.1
    }

    private func contextSwitchCount(_ samples: [SystemSample]) -> Int {
        var accepted: String?
        var candidate: String?
        var candidateCount = 0
        var switches = 0
        for sample in samples {
            let identity = sample.foregroundBundleID ?? sample.foregroundApp
            if identity == candidate { candidateCount += 1 }
            else { candidate = identity; candidateCount = 1 }
            guard candidateCount >= 2 else { continue }
            if let accepted, accepted != identity { switches += 1 }
            accepted = identity
        }
        return switches
    }

    private struct WindowedSample {
        let sample: SystemSample
        let duration: TimeInterval
    }

    private struct SegmentedWindowedSample {
        let value: WindowedSample
        let segment: Int
    }

    private struct ClippedAppResource {
        let sample: AppResourceSample
        let interval: DateInterval
        let duration: TimeInterval
        let fraction: Double
    }

    private func segmentedWindowedSamples(_ samples: [SystemSample], within interval: DateInterval) -> [SegmentedWindowedSample] {
        let ordered = samples.sorted { $0.timestamp < $1.timestamp }
        var result: [SegmentedWindowedSample] = []
        var previous: SystemSample?
        var segment = 0
        var pendingBreak = false

        for sample in ordered {
            guard sample.timestamp > interval.start, sample.timestamp <= interval.end else { continue }
            let duration = CoverageEvaluator.effectiveDuration(of: sample, within: interval)
            guard duration > 0 else {
                if !result.isEmpty {
                    pendingBreak = true
                    previous = nil
                }
                continue
            }

            var startsNewSegment = pendingBreak
            if let previous {
                let gap = sample.timestamp.timeIntervalSince(previous.timestamp)
                let expected = max(sample.samplingInterval, previous.samplingInterval)
                startsNewSegment = startsNewSegment || gap < 0 || gap > max(2, expected * 2.2)
            }
            if startsNewSegment, !result.isEmpty { segment += 1 }
            result.append(SegmentedWindowedSample(value: WindowedSample(sample: sample, duration: duration), segment: segment))
            previous = sample
            pendingBreak = false
        }

        return result
    }

    private func weightedWindowAverage(_ values: [WindowedSample], value: (SystemSample) -> Double) -> Double {
        let total = values.reduce(0) { $0 + $1.duration }
        guard total > 0 else { return 0 }
        return values.reduce(0) { $0 + value($1.sample) * $1.duration } / total
    }

    private func proportionalCounterTotal(
        _ values: [WindowedSample],
        value: (SystemSample) -> UInt64
    ) -> UInt64 {
        values.reduce(UInt64(0)) { total, item in
            let measuredDuration = CoverageEvaluator.boundedDuration(of: item.sample)
            guard measuredDuration > 0 else { return total }
            let fraction = min(1, max(0, item.duration / measuredDuration))
            return total &+ proportionalBytes(value(item.sample), fraction: fraction)
        }
    }

    private func clippedAppResources(
        _ samples: [AppResourceSample],
        within interval: DateInterval
    ) -> [ClippedAppResource] {
        samples.compactMap { sample in
            let measuredDuration = max(0, sample.duration)
            guard measuredDuration > 0 else { return nil }
            let measured = DateInterval(
                start: sample.timestamp.addingTimeInterval(-measuredDuration),
                end: sample.timestamp
            )
            let start = max(measured.start, interval.start)
            let end = min(measured.end, interval.end)
            guard end > start else { return nil }
            let duration = end.timeIntervalSince(start)
            return ClippedAppResource(
                sample: sample,
                interval: DateInterval(start: start, end: end),
                duration: duration,
                fraction: min(1, duration / measuredDuration)
            )
        }.sorted { $0.sample.timestamp < $1.sample.timestamp }
    }

    private func weightedAppAverage(
        _ values: [ClippedAppResource],
        value: (AppResourceSample) -> Double
    ) -> Double {
        let duration = values.reduce(0) { $0 + $1.duration }
        guard duration > 0 else { return 0 }
        return values.reduce(0) { $0 + value($1.sample) * $1.duration } / duration
    }

    private func proportionalAppCounterTotal(
        _ values: [ClippedAppResource],
        value: KeyPath<AppResourceSample, UInt64>
    ) -> UInt64 {
        values.reduce(UInt64(0)) {
            $0 &+ proportionalBytes($1.sample[keyPath: value], fraction: $1.fraction)
        }
    }

    private func proportionalBytes(_ value: UInt64, fraction: Double) -> UInt64 {
        let scaled = Double(value) * min(1, max(0, fraction))
        return UInt64(max(0, min(Double(UInt64.max), scaled)).rounded())
    }

    private func isMeasurableBackgroundActivity(_ item: ClippedAppResource) -> Bool {
        item.sample.cpuPercent >= 1
            || proportionalBytes(item.sample.diskReadBytes &+ item.sample.diskWriteBytes, fraction: item.fraction) >= 64 * 1_024
    }

    private func matchingSystemIntervals(
        _ samples: [SystemSample],
        within interval: DateInterval,
        matching predicate: (SystemSample) -> Bool
    ) -> [DateInterval] {
        let candidates = samples.compactMap { sample -> DateInterval? in
            guard predicate(sample) else { return nil }
            let duration = CoverageEvaluator.effectiveDuration(of: sample, within: interval)
            guard duration > 0 else { return nil }
            let end = min(sample.timestamp, interval.end)
            return DateInterval(start: max(interval.start, end.addingTimeInterval(-duration)), end: end)
        }.sorted { $0.start < $1.start }
        var merged: [DateInterval] = []
        for candidate in candidates {
            if let last = merged.last, candidate.start <= last.end {
                merged[merged.count - 1] = DateInterval(start: last.start, end: max(last.end, candidate.end))
            } else {
                merged.append(candidate)
            }
        }
        return merged
    }

    private func overlapDuration(of interval: DateInterval, with matches: [DateInterval]) -> TimeInterval {
        matches.reduce(0) { total, candidate in
            let start = max(interval.start, candidate.start)
            let end = min(interval.end, candidate.end)
            return total + max(0, end.timeIntervalSince(start))
        }
    }

    private func backgroundImpactScore(_ summary: BackgroundAppSummary) -> Double {
        summary.cpuCoreSeconds
            + Double(summary.diskReadBytes &+ summary.diskWriteBytes) / 1_000_000
            + Double(summary.peakMemoryBytes) / 1_000_000_000 * max(1, summary.backgroundDuration / 60) * 0.1
    }

    private func downsampleBackgroundPoints(
        _ points: [BackgroundActivityPoint],
        limit: Int
    ) -> [BackgroundActivityPoint] {
        guard points.count > limit, limit > 1 else { return Array(points.suffix(max(0, limit))) }
        var important: [UUID: BackgroundActivityPoint] = [:]
        important[points.first!.id] = points.first!
        important[points.last!.id] = points.last!
        for values in Dictionary(grouping: points, by: { $0.ownerBundleID ?? $0.ownerName }).values {
            let candidates = [
                values.first,
                values.last,
                values.max(by: { $0.cpuPercent < $1.cpuPercent }),
                values.max(by: { $0.memoryBytes < $1.memoryBytes }),
                values.max(by: { $0.diskBytes < $1.diskBytes }),
                values.max(by: { $0.agentWorkerCount < $1.agentWorkerCount })
            ].compactMap { $0 }
            for point in candidates { important[point.id] = point }
        }

        let importance: (BackgroundActivityPoint) -> Double = { point in
            point.cpuPercent
                + Double(point.memoryBytes) / 500_000_000
                + Double(point.diskBytes) / 250_000_000
                + Double(point.agentWorkerCount) * 100
        }
        var selected = Array(important.values)
            .sorted { importance($0) > importance($1) }
        if selected.count > limit { selected = Array(selected.prefix(limit)) }
        var selectedIDs = Set(selected.map(\.id))
        let remaining = limit - selected.count
        if remaining > 0 {
            let candidates = points.filter { !selectedIDs.contains($0.id) }
            if !candidates.isEmpty {
                for slot in 0..<remaining {
                    let index = min(candidates.count - 1, Int(Double(slot) / Double(max(1, remaining)) * Double(candidates.count)))
                    let point = candidates[index]
                    if selectedIDs.insert(point.id).inserted { selected.append(point) }
                }
            }
        }
        return selected.sorted { $0.timestamp < $1.timestamp }
    }

    private func summarizeMonitoringApps(_ samples: [WindowedSample]) -> [AppUsageSummary] {
        let groups = Dictionary(grouping: samples) { $0.sample.foregroundBundleID ?? $0.sample.foregroundApp }
        return groups.compactMap { _, values in
            guard let first = values.first?.sample else { return nil }
            let duration = values.reduce(0) { $0 + $1.duration }
            let cpu = weightedWindowAverage(values, value: \SystemSample.cpuPercent)
            let memory = UInt64(max(0, weightedWindowAverage(values) { Double($0.memoryUsedBytes) }))
            return AppUsageSummary(
                name: first.foregroundApp,
                bundleID: first.foregroundBundleID,
                activeDuration: duration,
                averageSystemCPU: cpu,
                averageMemoryBytes: memory,
                interpretation: "\(first.foregroundApp) was in front for about \(Formatters.duration(duration)) in this window. Whole-machine CPU averaged \(Formatters.percent(cpu)) during those intervals; that is workflow context, not attribution to the app alone."
            )
        }.sorted { lhs, rhs in
            if lhs.activeDuration != rhs.activeDuration {
                return lhs.activeDuration > rhs.activeDuration
            }
            let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return (lhs.bundleID ?? "") < (rhs.bundleID ?? "")
        }
    }

    private func summarizeMonitoringCategories(_ samples: [WindowedSample]) -> [CategorySummary] {
        let groups = Dictionary(grouping: samples) { $0.sample.category }
        return groups.map { category, values in
            let duration = values.reduce(0) { $0 + $1.duration }
            let cpu = weightedWindowAverage(values, value: \SystemSample.cpuPercent)
            return CategorySummary(
                category: category,
                activeDuration: duration,
                averageCPU: cpu,
                interpretation: "\(category.rawValue) accounted for \(Formatters.duration(duration)) of observed active use. Whole-machine CPU averaged \(Formatters.percent(cpu)) during those intervals; this is context rather than causal attribution."
            )
        }.sorted { lhs, rhs in
            lhs.activeDuration == rhs.activeDuration
                ? lhs.category.rawValue < rhs.category.rawValue
                : lhs.activeDuration > rhs.activeDuration
        }
    }

    private func monitoringContextSwitchCount(_ samples: [SegmentedWindowedSample]) -> Int {
        var currentSegment: Int?
        var accepted: String?
        var candidate: String?
        var candidateCount = 0
        var switches = 0

        for item in samples where !item.value.sample.isIdle {
            if currentSegment != item.segment {
                currentSegment = item.segment
                accepted = nil
                candidate = nil
                candidateCount = 0
            }
            let sample = item.value.sample
            let identity = sample.foregroundBundleID ?? sample.foregroundApp
            if identity == candidate {
                candidateCount += 1
            } else {
                candidate = identity
                candidateCount = 1
            }
            guard candidateCount >= 2 else { continue }
            if let accepted, accepted != identity { switches += 1 }
            accepted = identity
        }
        return switches
    }

    private func peakMemoryPressure(_ values: [MemoryPressureLevel]) -> MemoryPressureLevel {
        if values.contains(.high) { return .high }
        if values.contains(.elevated) { return .elevated }
        return .low
    }

    private func meaningfulSwapChange(_ samples: [SegmentedWindowedSample], within interval: DateInterval) -> Int64? {
        guard let first = samples.first, let last = samples.last,
              first.segment == last.segment,
              samples.allSatisfy({ $0.segment == first.segment }),
              samples.reduce(0, { $0 + $1.value.duration }) >= CoverageEvaluator.narrativeMinimum else { return nil }

        let firstSample = first.value.sample
        let firstStart = firstSample.timestamp.addingTimeInterval(-CoverageEvaluator.boundedDuration(of: firstSample))
        let endTolerance = max(120, last.value.sample.samplingInterval * 4)
        guard firstStart <= interval.start.addingTimeInterval(1),
              interval.end.timeIntervalSince(last.value.sample.timestamp) <= endTolerance else { return nil }

        let startValue = firstSample.swapUsedBytes
        let endValue = last.value.sample.swapUsedBytes
        if endValue >= startValue { return Int64(clamping: endValue - startValue) }
        return -Int64(clamping: startValue - endValue)
    }

    private func longestMatchingDuration(
        in samples: [SegmentedWindowedSample],
        matching predicate: (SystemSample) -> Bool
    ) -> TimeInterval {
        var longest: TimeInterval = 0
        var current: TimeInterval = 0
        var previousSegment: Int?
        for item in samples {
            if previousSegment != item.segment || !predicate(item.value.sample) {
                current = 0
            }
            if predicate(item.value.sample) {
                current += item.value.duration
                longest = max(longest, current)
            }
            previousSegment = item.segment
        }
        return longest
    }

    private func monitoringInsights(
        range: MonitoringRange,
        supportsNarrative: Bool,
        segmented: [SegmentedWindowedSample],
        observedDuration: TimeInterval,
        activeDuration: TimeInterval,
        averageCPU: Double,
        peakMemoryPressure: MemoryPressureLevel,
        elevatedMemoryDuration: TimeInterval,
        thermalPeak: ThermalLevel,
        swapChangeBytes: Int64?,
        contextSwitches: Int,
        applications: [AppUsageSummary]
    ) -> [ReportInsight] {
        guard supportsNarrative else {
            return [ReportInsight(
                kind: .observation,
                title: "Building a reliable picture",
                explanation: "No uninterrupted recorded stretch has reached about two minutes yet, so performance conclusions are being withheld."
            )]
        }

        var result: [ReportInsight] = []
        let sustainedCPU = longestMatchingDuration(in: segmented) { $0.cpuPercent >= 75 }
        if thermalPeak == .critical || thermalPeak == .serious {
            result.append(ReportInsight(
                kind: .caution,
                title: thermalPeak == .critical ? "Critical thermal pressure appeared" : "Serious thermal pressure appeared",
                explanation: "macOS reported \(thermalPeak.rawValue) thermal pressure in the recorded periods, so performance may have had less heat headroom."
            ))
        } else if peakMemoryPressure != .low, elevatedMemoryDuration >= 5 * 60 {
            result.append(ReportInsight(
                kind: .caution,
                title: "Memory demand stayed elevated",
                explanation: "Memory pressure remained above its comfortable range for \(Formatters.duration(elevatedMemoryDuration)) in the recorded periods."
            ))
        } else if sustainedCPU >= 2 * 60 {
            result.append(ReportInsight(
                kind: .caution,
                title: "A sustained processor-heavy stretch stood out",
                explanation: "Whole-machine CPU stayed at or above 75% for about \(Formatters.duration(sustainedCPU)), which can increase heat and battery use."
            ))
        } else if let swapChangeBytes, swapChangeBytes >= 512_000_000 {
            result.append(ReportInsight(
                kind: .observation,
                title: "Swap allocation grew during the continuous window",
                explanation: "Swap allocation increased by about \(Formatters.bytes(UInt64(swapChangeBytes))) while coverage remained continuous."
            ))
        } else {
            result.append(ReportInsight(
                kind: .efficient,
                title: "No sustained performance concern stood out",
                explanation: "Whole-machine CPU averaged \(Formatters.percent(averageCPU)), and no sustained CPU, memory-pressure, or heat concern appeared in the recorded periods."
            ))
        }

        if let top = applications.first, top.activeDuration >= 60 {
            result.append(ReportInsight(
                kind: .observation,
                title: "\(top.name) was in front the most",
                explanation: "It accounted for \(Formatters.duration(top.activeDuration)) of observed active use. Foreground time describes context, not attention or causation."
            ))
        }

        if activeDuration >= 30 * 60, contextSwitches >= 6 {
            let rate = Double(contextSwitches) / max(activeDuration / 3_600, 0.5)
            if rate >= 8 {
                result.append(ReportInsight(
                    kind: .observation,
                    title: "Foreground apps changed frequently",
                    explanation: "macOS reported about \(contextSwitches) confirmed changes, or roughly \(Int(rate.rounded())) per active hour. This does not measure focus."
                ))
            }
        }

        if result.count < 3, observedDuration < range.duration * 0.75 {
            result.append(ReportInsight(
                kind: .observation,
                title: "Part of this window is unrecorded",
                explanation: "The monitor recorded \(Formatters.duration(observedDuration)) of this \(range.label) view. Sleep, pauses, or time when the app was closed remain visible as gaps."
            ))
        }

        return Array(result.prefix(3))
    }

    private func downsampleMonitoringPoints(
        _ points: [SegmentedWindowedSample],
        interval: DateInterval,
        limit: Int
    ) -> [SegmentedWindowedSample] {
        guard points.count > limit else { return points }
        if limit == 1 { return [points.last!] }
        _ = interval
        var selected: [UUID: SegmentedWindowedSample] = [:]
        func add(_ point: SegmentedWindowedSample?) {
            guard selected.count < limit, let point else { return }
            selected[point.value.sample.id] = point
        }
        func add(contentsOf values: [SegmentedWindowedSample]) {
            for point in values where selected.count < limit { add(point) }
        }

        // Window endpoints and global extrema protect the meaning of every chart mode.
        add(points.first)
        add(points.last)
        add(points.min { $0.value.sample.cpuPercent < $1.value.sample.cpuPercent })
        add(points.max { $0.value.sample.cpuPercent < $1.value.sample.cpuPercent })
        add(points.max { $0.value.sample.memoryUsedBytes < $1.value.sample.memoryUsedBytes })
        add(points.max { $0.value.sample.swapUsedBytes < $1.value.sample.swapUsedBytes })
        add(points.max { monitoringDiskBytes($0) < monitoringDiskBytes($1) })
        add(points.max { monitoringNetworkBytes($0) < monitoringNetworkBytes($1) })
        add(points.max { monitoringKeyboardEvents($0) < monitoringKeyboardEvents($1) })
        add(points.max { monitoringPointerEvents($0) < monitoringPointerEvents($1) })
        add(points.max { monitoringClickEvents($0) < monitoringClickEvents($1) })
        add(points.max { monitoringScrollEvents($0) < monitoringScrollEvents($1) })
        add(points.max { monitoringManualIntensity($0) < monitoringManualIntensity($1) })
        add(points.max { lhs, rhs in
            let left = pressureRank(lhs.value.sample.memoryPressure)
            let right = pressureRank(rhs.value.sample.memoryPressure)
            return left == right ? lhs.value.sample.memoryUsedBytes < rhs.value.sample.memoryUsedBytes : left < right
        })
        add(points.max { lhs, rhs in
            let left = thermalRank(lhs.value.sample.thermalLevel)
            let right = thermalRank(rhs.value.sample.thermalLevel)
            return left == right ? lhs.value.sample.cpuPercent < rhs.value.sample.cpuPercent : left < right
        })

        let battery = points.filter { $0.value.sample.batteryPercent != nil }
        add(battery.first)
        add(battery.last)
        add(battery.min { ($0.value.sample.batteryPercent ?? 0) < ($1.value.sample.batteryPercent ?? 0) })
        add(battery.max { ($0.value.sample.batteryPercent ?? 0) < ($1.value.sample.batteryPercent ?? 0) })

        // Preserve both sides of pressure, thermal, power-source, and recording-gap
        // transitions so a short non-CPU event cannot disappear during downsampling.
        for index in points.indices.dropFirst() where selected.count < limit {
            let previous = points[index - 1]
            let current = points[index]
            let previousSample = previous.value.sample
            let currentSample = current.value.sample
            if previous.segment != current.segment
                || previousSample.memoryPressure != currentSample.memoryPressure
                || previousSample.thermalLevel != currentSample.thermalLevel
                || previousSample.powerSource != currentSample.powerSource
                || (previousSample.manualActivity == nil) != (currentSample.manualActivity == nil) {
                add(previous)
                add(current)
            }
        }

        // Every continuous segment keeps its own visual endpoints.
        let pointsBySegment = Dictionary(grouping: points, by: \.segment)
        for segment in pointsBySegment.keys.sorted() where selected.count < limit {
            guard let values = pointsBySegment[segment] else { continue }
            add(values.first)
            add(values.last)
        }

        // Use the remaining budget evenly across time. Each bucket contributes CPU low/high
        // plus the most consequential non-CPU interval (pressure/thermal/I-O/memory).
        let remaining = limit - selected.count
        if remaining > 0 {
            let bucketCount = max(1, remaining / 3)
            var buckets = Array(repeating: [SegmentedWindowedSample](), count: bucketCount)
            for (index, point) in points.enumerated() {
                let bucket = min(bucketCount - 1, index * bucketCount / points.count)
                buckets[bucket].append(point)
            }
            for bucket in buckets where !bucket.isEmpty && selected.count < limit {
                add(bucket.min { $0.value.sample.cpuPercent < $1.value.sample.cpuPercent })
                add(bucket.max { $0.value.sample.cpuPercent < $1.value.sample.cpuPercent })
                add(bucket.max { monitoringNonCPUScore($0) < monitoringNonCPUScore($1) })
            }
        }

        if selected.count < limit {
            let candidates = points.filter { selected[$0.value.sample.id] == nil }
            let needed = limit - selected.count
            if !candidates.isEmpty {
                for slot in 0..<needed {
                    let index = min(candidates.count - 1, slot * candidates.count / max(1, needed))
                    add(candidates[index])
                }
            }
        }
        return selected.values.sorted { $0.value.sample.timestamp < $1.value.sample.timestamp }
    }

    private func monitoringDiskBytes(_ point: SegmentedWindowedSample) -> UInt64 {
        point.value.sample.diskReadBytes &+ point.value.sample.diskWriteBytes
    }

    private func monitoringNetworkBytes(_ point: SegmentedWindowedSample) -> UInt64 {
        point.value.sample.networkReceivedBytes &+ point.value.sample.networkSentBytes
    }

    private func monitoringKeyboardEvents(_ point: SegmentedWindowedSample) -> UInt64 {
        point.value.sample.manualActivity?.keyboardEvents ?? 0
    }

    private func monitoringPointerEvents(_ point: SegmentedWindowedSample) -> UInt64 {
        point.value.sample.manualActivity?.pointerEvents ?? 0
    }

    private func monitoringClickEvents(_ point: SegmentedWindowedSample) -> UInt64 {
        point.value.sample.manualActivity?.clickEvents ?? 0
    }

    private func monitoringScrollEvents(_ point: SegmentedWindowedSample) -> UInt64 {
        point.value.sample.manualActivity?.scrollEvents ?? 0
    }

    private func monitoringManualIntensity(_ point: SegmentedWindowedSample) -> Double {
        point.value.sample.manualActivity?.intensity(over: point.value.duration) ?? 0
    }

    private func monitoringNonCPUScore(_ point: SegmentedWindowedSample) -> Double {
        let sample = point.value.sample
        return Double(pressureRank(sample.memoryPressure)) * 1e18
            + Double(thermalRank(sample.thermalLevel)) * 1e17
            + monitoringManualIntensity(point) * 1e16
            + log1p(Double(monitoringDiskBytes(point))) * 1e12
            + log1p(Double(monitoringNetworkBytes(point))) * 1e9
            + log1p(Double(sample.memoryUsedBytes)) * 1e6
            + Double(sample.batteryPercent ?? 0)
    }

    private func pressureRank(_ value: MemoryPressureLevel) -> Int {
        switch value {
        case .low: return 0
        case .elevated: return 1
        case .high: return 2
        }
    }

    private func thermalRank(_ value: ThermalLevel) -> Int {
        switch value {
        case .unknown: return 0
        case .nominal: return 1
        case .fair: return 2
        case .serious: return 3
        case .critical: return 4
        }
    }

    private func weightedAverage<T>(_ values: [T], value: (T) -> Double, duration: (T) -> TimeInterval) -> Double {
        let total = values.reduce(0) { $0 + max(0, duration($1)) }
        guard total > 0 else { return values.isEmpty ? 0 : values.map(value).reduce(0, +) / Double(values.count) }
        return values.reduce(0) { $0 + value($1) * max(0, duration($1)) } / total
    }

    private func weightedAverage(_ values: [SystemSample], value: (SystemSample) -> Double) -> Double {
        weightedAverage(values, value: value, duration: { boundedDuration($0) })
    }

    private func boundedDuration(_ sample: SystemSample) -> TimeInterval {
        min(max(1, sample.duration), max(2, sample.samplingInterval * 2.2))
    }

    private func peakThermal(_ values: [ThermalLevel]) -> ThermalLevel {
        let rank: [ThermalLevel: Int] = [.unknown: 0, .nominal: 1, .fair: 2, .serious: 3, .critical: 4]
        return values.max { rank[$0, default: 0] < rank[$1, default: 0] } ?? .unknown
    }

    private struct Segment {
        let start: Date
        let duration: TimeInterval
        let samples: [SystemSample]
    }

    private func segments(samples: [SystemSample], matching predicate: (SystemSample) -> Bool) -> [Segment] {
        var result: [Segment] = []
        var current: [SystemSample] = []
        func finish() {
            guard let first = current.first else { return }
            result.append(Segment(start: first.timestamp, duration: current.reduce(0) { $0 + boundedDuration($1) }, samples: current))
            current = []
        }
        for sample in samples {
            if predicate(sample) {
                if let last = current.last, sample.timestamp.timeIntervalSince(last.timestamp) > max(sample.samplingInterval, last.samplingInterval) * 3 { finish() }
                current.append(sample)
            } else {
                finish()
            }
        }
        finish()
        return result
    }

    private func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func hasSample(near date: Date, in orderedSamples: [SystemSample], tolerance: TimeInterval) -> Bool {
        guard !orderedSamples.isEmpty else { return false }
        var low = 0
        var high = orderedSamples.count
        while low < high {
            let middle = (low + high) / 2
            if orderedSamples[middle].timestamp < date { low = middle + 1 }
            else { high = middle }
        }
        if low < orderedSamples.count, abs(orderedSamples[low].timestamp.timeIntervalSince(date)) <= tolerance { return true }
        if low > 0, abs(orderedSamples[low - 1].timestamp.timeIntervalSince(date)) <= tolerance { return true }
        return false
    }

    private func naturalList<S: Sequence>(_ values: S) -> String where S.Element == String {
        let array = Array(values)
        if array.count <= 1 { return array.first ?? "" }
        if array.count == 2 { return array.joined(separator: " and ") }
        return array.dropLast().joined(separator: ", ") + ", and " + array.last!
    }

    private func mostCommon<T: Hashable>(_ values: [T]) -> T? {
        Dictionary(grouping: values, by: { $0 }).max { $0.value.count < $1.value.count }?.key
    }

    private func trendChange(_ reports: [DailyReport]) -> String? {
        guard reports.count >= 7 else { return nil }
        let recentCount = max(2, reports.count / 2)
        let recent = Array(reports.prefix(recentCount))
        let earlier = Array(reports.dropFirst(recentCount))
        guard !earlier.isEmpty else { return nil }
        let recentCPU = recent.map(\.averageCPU).reduce(0, +) / Double(recent.count)
        let earlierCPU = earlier.map(\.averageCPU).reduce(0, +) / Double(earlier.count)
        guard earlierCPU >= 5 else { return nil }
        let change = (recentCPU - earlierCPU) / earlierCPU
        if change >= 0.25 { return "Processor demand in the most recent days was about \(Formatters.percent(change * 100)) higher than the earlier part of this window." }
        if change <= -0.25 { return "Processor demand in the most recent days was about \(Formatters.percent(abs(change) * 100)) lower than the earlier part of this window." }
        return nil
    }
}
