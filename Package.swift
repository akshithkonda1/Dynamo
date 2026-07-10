// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Dynamo",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Dynamo", targets: ["Dynamo"])
    ],
    targets: [
        // The Swift Package builds the same sources for fast compile iteration
        // and CI. The shippable, WeatherKit-signed app is built from the Xcode
        // target described in `project.yml` (XcodeGen) — that real `.app` bundle
        // carries `Info.plist` and `Dynamo.entitlements` properly, so the old
        // linker `-sectcreate __TEXT __info_plist` trick is no longer needed.
        .executableTarget(
            name: "Dynamo",
            path: "Sources/Dynamo",
            exclude: ["Info.plist", "Dynamo.entitlements"],
            resources: [
                .process("Resources")
            ]
        )
    ]
)
