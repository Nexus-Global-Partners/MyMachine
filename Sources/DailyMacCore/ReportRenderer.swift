import Foundation

public enum ReportRenderer {
    public static func markdown(_ report: DailyReport) -> String {
        var lines: [String] = [
            "# MY MACHINE — \(escape(report.dayKey))",
            "",
            "_Generated locally at \(report.generatedAt.formatted(date: .abbreviated, time: .shortened))._",
            "",
            "## In brief",
            "",
            "**\(escape(report.headline))**",
            "",
            escape(report.overview),
            "",
            "Coverage: \(Formatters.duration(report.activeDuration + report.idleDuration)); longest uninterrupted stretch: \(Formatters.duration(report.longestContinuousCoverage ?? 0)); active app use: \(Formatters.duration(report.activeDuration)); idle time excluded: \(Formatters.duration(report.idleDuration))."
        ]
        let supportsNarrative = (report.longestContinuousCoverage ?? 0) >= CoverageEvaluator.narrativeMinimum
        if !supportsNarrative {
            lines += [
                "",
                "## Interpretation",
                "",
                "No performance, battery, heat, or workflow conclusion is justified from these fragments. MY MACHINE will wait for a longer uninterrupted observation before suggesting anything.",
                "",
                "## Method and limitations",
                ""
            ]
            for limitation in report.limitations { lines.append("- \(escape(limitation))") }
            lines.append("")
            lines.append(privacyFooter)
            return lines.joined(separator: "\n")
        }

        lines += ["", "## How the Mac was used", ""]
        for app in report.applications.prefix(5) {
            lines.append("- **\(escape(app.name))** — \(escape(app.interpretation))")
        }
        lines += ["", "## How the machine behaved", ""]
        lines.append("- CPU averaged \(Formatters.percent(report.averageCPU)) and peaked at \(Formatters.percent(report.peakCPU)). \(PracticalInterpreter.cpu(report.averageCPU))")
        let pressure = report.peakMemoryPressure ?? .low
        let totalMemory = report.memoryTotalBytes ?? max(report.peakMemoryBytes, 1)
        lines.append("- \(PracticalInterpreter.memory(used: report.peakMemoryBytes, total: totalMemory, pressure: pressure, swap: report.endingSwapBytes)) Highest observed active/wired/compressed memory: \(Formatters.bytes(report.peakMemoryBytes)); ending swap allocation: \(Formatters.bytes(report.endingSwapBytes)).")
        lines.append("- The highest thermal state was **\(report.thermalPeak.rawValue)**. \(report.thermalPeak.explanation)")
        if let change = report.batteryChangePercent, change < 0 {
            lines.append("- Battery level fell by about \(Formatters.percent(abs(change))) during the longest sufficiently covered continuous discharge period. This affects runtime but does not identify a single app as the cause.")
        }
        if let disk = report.totalDiskBytes, let network = report.totalNetworkBytes {
            lines.append("- \(PracticalInterpreter.io(diskBytes: disk, networkBytes: network, observedDuration: report.activeDuration + report.idleDuration)) Observed counter totals: \(Formatters.bytes(disk)) disk and \(Formatters.bytes(network)) network. VPN and virtual-interface paths can overlap, so network bytes are context rather than exact internet-transfer accounting.")
        }
        lines += ["", "## Important moments", ""]
        if report.importantMoments.isEmpty { lines.append("No disruptive performance event stood out in the recorded periods.") }
        for insight in report.importantMoments { lines.append("- **\(escape(insight.title))** — \(escape(insight.explanation))") }
        lines += ["", "## Work × machine patterns", ""]
        for insight in report.correlations { lines.append("- **\(escape(insight.title))** — \(escape(insight.explanation))") }
        lines += ["", "## What I would change tomorrow", ""]
        if report.recommendations.isEmpty {
            lines.append("No data-backed change is justified today. Keep working normally while MY MACHINE builds a stronger baseline.")
        } else {
            for insight in report.recommendations {
                lines.append("- **\(escape(insight.title))** — \(escape(insight.explanation))")
                if let evidence = insight.evidence { lines.append("  - Evidence: \(escape(evidence))") }
            }
        }
        lines += ["", "## Method and limitations", ""]
        for limitation in report.limitations { lines.append("- \(escape(limitation))") }
        lines.append("")
        lines.append(privacyFooter)
        return lines.joined(separator: "\n")
    }

    private static let privacyFooter = "MY MACHINE stores this report and its telemetry locally. It does not capture keystrokes or what you type; only interval input totals are used for hands-on intensity. It never captures pointer coordinates or targets, screen contents, window titles, URLs, document contents, clipboard data, message contents, paths, or network destinations."

    private static func escape(_ value: String) -> String {
        // Every persisted string is data, including prose containing app names.
        // Escape CommonMark ASCII punctuation and flatten control/line characters
        // before adding trusted report formatting. Also neutralizes HTML/autolinks.
        let controls = CharacterSet.controlCharacters.union(.newlines)
        let bidi = CharacterSet(charactersIn: "\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}")
        var result = ""
        for scalar in value.unicodeScalars {
            if bidi.contains(scalar) { continue }
            if controls.contains(scalar) { result.append(" "); continue }
            let code = scalar.value
            if (33...47).contains(code) || (58...64).contains(code) ||
                (91...96).contains(code) || (123...126).contains(code) {
                result.append("\\")
            }
            result.unicodeScalars.append(scalar)
        }
        return result
    }
}
