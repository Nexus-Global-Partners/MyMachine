import AppKit
import UniformTypeIdentifiers

/// Resolves application art once per identity. Icons and application paths stay
/// in memory only and never enter telemetry, persistence, or diagnosis exports.
@MainActor
final class ApplicationIconCache {
    static let shared = ApplicationIconCache()

    private let images = NSCache<NSString, NSImage>()

    private init() {
        images.countLimit = 96
    }

    func image(bundleIdentifier: String?, ownerName: String) -> NSImage {
        let key = (bundleIdentifier ?? "name:\(ownerName)") as NSString
        if let cached = images.object(forKey: key) { return cached }

        let resolved = resolve(bundleIdentifier: bundleIdentifier) ?? fallbackIcon()
        let copy = (resolved.copy() as? NSImage) ?? resolved
        copy.size = NSSize(width: 24, height: 24)
        images.setObject(copy, forKey: key)
        return copy
    }

    private func resolve(bundleIdentifier: String?) -> NSImage? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
        if let runningURL = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first?
            .bundleURL {
            return NSWorkspace.shared.icon(forFile: runningURL.path)
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private func fallbackIcon() -> NSImage {
        NSImage(systemSymbolName: "app.fill", accessibilityDescription: "Application")
            ?? NSWorkspace.shared.icon(for: .applicationBundle)
    }
}
