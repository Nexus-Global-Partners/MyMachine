import Foundation

public enum MetricCatalog {
    public static let disclosures: [MetricDisclosure] = [
        MetricDisclosure(
            metric: "Applications and active time", origin: .measured,
            plainLanguage: "Which application was in front, and whether you were actively using the Mac.",
            technicalDetail: "Read from NSWorkspace foreground application metadata and time since the last input event. No input content is captured."
        ),
        MetricDisclosure(
            metric: "Hands-on activity", origin: .derived,
            plainLanguage: "How light or intense your physical interaction with the Mac was during a recorded interval.",
            technicalDetail: "Derived locally from permission-free deltas of public Quartz event totals for keyboard actions, pointer movement or dragging, clicks, and scrolling. MY MACHINE never installs an event tap and never reads or stores keys, text, coordinates, targets, window content, or event payloads. This describes input density, not attention, effort quality, or productivity."
        ),
        MetricDisclosure(
            metric: "Work category", origin: .estimated,
            plainLanguage: "A broad description such as coding, research, writing, or communication.",
            technicalDetail: "Inferred locally from application name and bundle identifier. Window titles and document contents are not used."
        ),
        MetricDisclosure(
            metric: "CPU", origin: .measured,
            plainLanguage: "How much of the Mac's total processing capacity was busy.",
            technicalDetail: "Calculated from deltas in Mach host CPU tick counters and normalized to the whole machine."
        ),
        MetricDisclosure(
            metric: "CPU core distribution", origin: .derived,
            plainLanguage: "How recorded CPU work was divided between faster performance cores and lower-power efficiency cores.",
            technicalDetail: "Derived locally from per-processor Mach tick deltas and the Mac's hardware core-cluster labels. The split describes busy time, not clock speed, energy use, or equal work per core. It is hidden when macOS does not expose a complete, verifiable topology."
        ),
        MetricDisclosure(
            metric: "Memory", origin: .measured,
            plainLanguage: "How much memory macOS actively needed, excluding readily reclaimable cache.",
            technicalDetail: "The active, wired, and compressed footprint is read from Mach VM statistics and compared with hardware memory size. It is intentionally not labeled as Activity Monitor’s broader PhysMem-used value."
        ),
        MetricDisclosure(
            metric: "Memory pressure", origin: .derived,
            plainLanguage: "Whether memory demand was comfortable or likely to affect responsiveness.",
            technicalDetail: "Conservatively derived from free/speculative memory, compression, and swap growth. It is not Activity Monitor's private pressure score."
        ),
        MetricDisclosure(
            metric: "Swap", origin: .measured,
            plainLanguage: "How much disk space macOS was using as overflow memory.",
            technicalDetail: "Read from the public vm.swapusage system control."
        ),
        MetricDisclosure(
            metric: "Battery and charging", origin: .measured,
            plainLanguage: "Battery level, power source, and charging state.",
            technicalDetail: "Read directly from IOKit power-source APIs. No electrical power or per-app battery use is claimed."
        ),
        MetricDisclosure(
            metric: "Battery change", origin: .derived,
            plainLanguage: "How much charge changed across a sufficiently covered continuous discharge period.",
            technicalDetail: "Derived only from battery readings at least 20 minutes apart without charging, sleep, or a large data gap. It is not a watt measurement and is not attributed to an app."
        ),
        MetricDisclosure(
            metric: "Thermal state", origin: .measured,
            plainLanguage: "Whether heat was beginning to constrain the Mac.",
            technicalDetail: "Read from ProcessInfo's system thermal state. Exact temperatures are intentionally not claimed."
        ),
        MetricDisclosure(
            metric: "Disk activity", origin: .measured,
            plainLanguage: "How much data processes read or wrote during the interval.",
            technicalDetail: "Calculated from documented IOKit block-storage byte counters. Per-process attribution is separate, best-effort, and may omit protected processes."
        ),
        MetricDisclosure(
            metric: "Network activity", origin: .measured,
            plainLanguage: "Total bytes sent and received, without destinations or content.",
            technicalDetail: "Calculated from byte counters on active network interfaces, excluding loopback. VPN and virtual-interface paths can overlap, so totals are useful as activity context but not exact internet-transfer accounting."
        ),
        MetricDisclosure(
            metric: "App families and process impact", origin: .measured,
            plainLanguage: "Which apps—including related background helpers and workers—were associated with meaningful processor, memory, or file/disk activity.",
            technicalDetail: "Process parent relationships and owning-app identity are resolved locally to combine related processes into app-family rollups. Coverage is best-effort and may omit protected processes. Memory footprint can include shared pages; process read/write counters are observed activity, not storage consumed, files changed, or SSD wear. App/process names, owner relationships, and counters stay local; command lines, workspace names, prompts, file paths or contents, and network destinations are not collected."
        ),
        MetricDisclosure(
            metric: "Energy Impact", origin: .unavailable,
            plainLanguage: "Not shown because Activity Monitor’s score is not available through a stable supported API.",
            technicalDetail: "MY MACHINE uses measured CPU and thermal state, plus derived battery change, as practical context instead of relabeling a kernel counter as electrical energy or inventing an Energy Impact score."
        ),
        MetricDisclosure(
            metric: "GPU activity estimate", origin: .estimated,
            plainLanguage: "When this Mac’s graphics driver makes it available, an estimate shows how busy the graphics engine was.",
            technicalDetail: "Read without extra permissions from an optional aggregate utilization value exposed by the installed graphics driver. Availability can differ between Macs, so the line is hidden when the value is absent. It is hardware activity only: no screen content, app content, private frameworks, or privileged tracing is used."
        ),
        MetricDisclosure(
            metric: "Fan speed and temperatures", origin: .unavailable,
            plainLanguage: "Not shown; the supported thermal state is used instead.",
            technicalDetail: "Fan RPM and sensor temperatures would require model-specific or unsupported interfaces, so MY MACHINE does not claim them."
        )
    ]
}
