// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Peaky",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Peaky",
            path: "Sources/Peaky",
            linkerSettings: [
                .linkedFramework("IOBluetooth"),
                .linkedFramework("EventKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Quartz"),
            ]
        ),
        .testTarget(
            name: "PeakyTests",
            dependencies: ["Peaky"],
            path: "Tests/PeakyTests"
        ),
    ]
)
