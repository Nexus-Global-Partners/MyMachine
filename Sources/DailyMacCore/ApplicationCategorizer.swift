import Foundation

public struct ApplicationCategorizer: Sendable {
    public init() {}

    public func category(appName: String, bundleID: String?) -> WorkCategory {
        let value = "\(appName) \(bundleID ?? "")".lowercased()

        if matches(value, ["xcode", "visual studio code", "vscode", "cursor", "zed", "sublime", "terminal", "iterm", "warp", "codex", "conductor", "github desktop", "tower", "fork", "jetbrains", "intellij", "pycharm", "webstorm", "android studio", "nova", "textmate"]) {
            return .coding
        }
        if matches(value, ["safari", "chrome", "chromium", "firefox", "arc", "brave", "orion", "edge", "vivaldi", "duckduckgo"]) {
            return .research
        }
        if matches(value, ["pages", "microsoft word", "obsidian", "bear", "ulysses", "notion", "ia writer", "typora", "drafts", "textedit", "notes", "scrivener", "grammarly"]) {
            return .writing
        }
        if matches(value, ["mail", "messages", "slack", "discord", "telegram", "signal", "whatsapp", "teams", "outlook", "spark", "missive"]) {
            return .communication
        }
        if matches(value, ["zoom", "webex", "around", "facetime", "meet", "loom", "mmhmm"]) {
            return .meetings
        }
        if matches(value, ["figma", "sketch", "affinity", "photoshop", "illustrator", "indesign", "canva", "pixelmator", "principle", "framer"]) {
            return .design
        }
        if matches(value, ["finder", "path finder", "commander one", "transmit", "forklift", "archive utility", "disk utility"]) {
            return .files
        }
        if matches(value, ["spotify", "music", "tidal", "deezer", "soundcloud", "podcasts", "overcast"]),
           !matches(value, ["music production"]) {
            return .music
        }
        if matches(value, ["quicktime", "vlc", "iina", "netflix", "tv", "youtube", "plex", "photos", "final cut", "premiere", "davinci resolve"]) {
            return .media
        }
        if matches(value, ["calendar", "reminders", "contacts", "system settings", "system preferences", "activity monitor", "keychain access", "1password", "bitwarden", "calculator", "app store"] ) {
            return .administration
        }
        return .other
    }

    private func matches(_ value: String, _ needles: [String]) -> Bool {
        needles.contains { value.contains($0) }
    }
}

public enum PracticalInterpreter {
    public static func cpu(_ value: Double, sustainedFor duration: TimeInterval? = nil) -> String {
        let persistence = duration.map { " for \(Formatters.duration($0))" } ?? ""
        switch value {
        case ..<25:
            return "CPU demand was light\(persistence), leaving substantial headroom for other work. No action is needed."
        case ..<55:
            return "CPU demand was moderate\(persistence). This is normal for active work and should not have affected responsiveness. No action is needed."
        case ..<80:
            return "CPU demand was high\(persistence). The Mac was working hard, which can increase heat and battery use, though foreground performance may still have felt normal. Act only if it persisted after the task ended."
        default:
            return "CPU demand was very high\(persistence). If sustained, this can raise heat, shorten battery life, and make concurrent work less responsive. Finishing unneeded heavy work can help."
        }
    }

    public static func memory(used: UInt64, total: UInt64, pressure: MemoryPressureLevel, swap: UInt64) -> String {
        switch pressure {
        case .low:
            return "Memory demand stayed comfortable. macOS had enough reclaimable capacity, so app switching should have remained responsive. No action is needed."
        case .elevated:
            return "Memory demand was elevated, with \(Formatters.bytes(swap)) of swap allocated. Switching among several heavy apps may have felt slower. This is noticeable, not dangerous; close a finished heavy app only if you feel slowdown."
        case .high:
            return "Memory was constrained and macOS was relying substantially on compression or disk-backed swap. Heavy app switching was likely slower; finishing or closing an unneeded heavy workload is the useful next step."
        }
    }

    public static func process(name: String, cpu: Double, memory: UInt64, diskBytes: UInt64, isForeground: Bool) -> String {
        var effects: [String] = []
        if cpu >= 100 { effects.append("was keeping at least one CPU core-equivalent busy") }
        else if cpu >= 20 { effects.append("was doing noticeable processor work") }
        if memory >= 4_000_000_000 { effects.append("held \(Formatters.bytes(memory)) of memory") }
        else if memory >= 1_000_000_000 { effects.append("used \(Formatters.bytes(memory)) of memory") }
        if diskBytes >= 1_000_000_000 { effects.append("moved \(Formatters.bytes(diskBytes)) on disk") }

        let role = isForeground ? "while it was in front" : "while it was not frontmost"
        guard !effects.isEmpty else {
            return "\(name) was sampled \(role) and was not placing unusual demand on the Mac."
        }
        let joined = effects.count == 1 ? effects[0] : effects.dropLast().joined(separator: ", ") + " and " + effects.last!
        let consequence: String
        if cpu >= 100 { consequence = "This could affect heat and battery life if it continued, especially alongside other heavy processes." }
        else if memory >= 4_000_000_000 { consequence = "That matters mainly when several other memory-heavy apps are open." }
        else { consequence = "This was noticeable, but not necessarily a problem." }
        return "\(name) \(joined) \(role). \(consequence)"
    }

    public static func io(diskBytes: UInt64, networkBytes: UInt64, observedDuration: TimeInterval) -> String {
        let hours = max(observedDuration / 3_600, 0.25)
        let diskPerHour = Double(diskBytes) / hours
        let networkPerHour = Double(networkBytes) / hours
        if diskPerHour >= 5_000_000_000 {
            return "Disk activity was substantial for the recorded time. Builds, large file operations, indexing, or macOS maintenance are plausible causes, but aggregate totals cannot identify which one. This matters if the Mac felt less responsive; otherwise no action is needed. Network traffic totaled \(Formatters.bytes(networkBytes))."
        }
        if networkPerHour >= 5_000_000_000 {
            return "Network activity was substantial for the recorded time. Large transfers can use battery and compete with other network work, but MY MACHINE cannot see destinations or identify the cause. Disk traffic totaled \(Formatters.bytes(diskBytes))."
        }
        return "Disk and network activity did not cross the app’s conservative high-activity thresholds in the recorded periods. Nothing in these totals suggests they were limiting the workflow, and no action is suggested."
    }
}
