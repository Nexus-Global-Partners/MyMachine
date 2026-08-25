// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MY-MACHINE",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "DailyMacCore", targets: ["DailyMacCore"]),
        .executable(name: "DailyMac", targets: ["DailyMacApp"]),
        .executable(name: "DailyMacValidation", targets: ["DailyMacValidation"])
    ],
    targets: [
        .target(
            name: "DailyMacCore",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit")
            ]
        ),
        .executableTarget(
            name: "DailyMacApp",
            dependencies: ["DailyMacCore"],
            linkerSettings: [
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Charts")
            ]
        ),
        .executableTarget(
            name: "DailyMacValidation",
            dependencies: ["DailyMacCore"]
        )
    ],
    swiftLanguageModes: [.v5]
)
