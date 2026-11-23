// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "fanctl",
    platforms: [.macOS(.v26)],
    targets: [
        .target(
            name: "CSMC",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        .target(name: "Sensors", dependencies: ["CSMC"]),
        .executableTarget(name: "fanctld", dependencies: ["CSMC"]),
        .executableTarget(name: "fanctl", dependencies: ["CSMC", "Sensors"]),
        .executableTarget(name: "FanBar", dependencies: ["CSMC", "Sensors"]),
    ],
    swiftLanguageModes: [.v5]
)
