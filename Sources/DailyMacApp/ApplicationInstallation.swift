import Foundation

enum ApplicationInstallation {
    static let expectedBundleIdentifier = "local.mymachine.app"

    static var isCanonicalApplicationsInstall: Bool {
        guard Bundle.main.bundleIdentifier == expectedBundleIdentifier else { return false }

        let bundleURL = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        let applicationsURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard bundleURL.pathExtension.lowercased() == "app" else { return false }

        let applicationsPath = applicationsURL.path.hasSuffix("/")
            ? applicationsURL.path
            : applicationsURL.path + "/"
        return bundleURL.path.hasPrefix(applicationsPath)
    }
}
