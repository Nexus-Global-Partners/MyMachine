import Foundation

/// Removes application identities and every free-text field that can embed them.
/// Numeric trends survive; these personal aggregates are not anonymous user data.
public enum ReportPrivacy {
    public static func removingApplicationDetails(from report: DailyReport) -> DailyReport {
        DailyReport(
            dayKey: report.dayKey,
            generatedAt: report.generatedAt,
            timezoneIdentifier: report.timezoneIdentifier,
            headline: "Daily machine-performance summary",
            overview: "Application details and original narrative expired under your retention settings. Aggregate trends remain available.",
            activeDuration: report.activeDuration,
            idleDuration: report.idleDuration,
            contextSwitches: report.contextSwitches,
            averageCPU: report.averageCPU,
            peakCPU: report.peakCPU,
            averageMemoryBytes: report.averageMemoryBytes,
            peakMemoryBytes: report.peakMemoryBytes,
            endingSwapBytes: report.endingSwapBytes,
            memoryTotalBytes: report.memoryTotalBytes,
            peakMemoryPressure: report.peakMemoryPressure,
            totalDiskBytes: report.totalDiskBytes,
            totalNetworkBytes: report.totalNetworkBytes,
            batteryChangePercent: report.batteryChangePercent,
            thermalPeak: report.thermalPeak,
            applications: [],
            categories: report.categories.map {
                CategorySummary(category: $0.category, activeDuration: $0.activeDuration,
                                averageCPU: $0.averageCPU, interpretation: "Aggregated application category; individual application details have expired.")
            },
            importantMoments: [], correlations: [], recommendations: [],
            limitations: ["The report day is the original local calendar day. Application names, identifiers and original narrative are no longer retained."],
            sampleCount: report.sampleCount,
            longestContinuousCoverage: report.longestContinuousCoverage,
            applicationDetailsRemoved: true
        )
    }
}
