// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Dynamo",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Dynamo", targets: ["Dynamo"]),
        .executable(name: "DynamoMediaRemoteHelper", targets: ["DynamoMediaRemoteHelper"])
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
            // Asset catalog lives in Resources for the Xcode app target only.
            // Processing it via SPM triggers actool + codesign on a resource
            // bundle that often fails with "resource fork … not allowed".
            exclude: [
                "Info.plist",
                "Dynamo.entitlements",
                "Resources/Assets.xcassets"
            ],
            resources: [
                .copy("Resources/AppIcon.icns")
            ]
        ),
        // Standalone MediaRemote helper process — see its own doc comment and
        // MediaRemoteHelperProcess.swift for why it's a separate binary.
        // Deliberately has no dependency on the Dynamo target; it's meant to
        // stay a minimal, independent binary.
        .executableTarget(
            name: "DynamoMediaRemoteHelper",
            path: "Sources/DynamoMediaRemoteHelper"
        ),
        .testTarget(
            name: "DynamoTests",
            dependencies: ["Dynamo"],
            path: "Tests/DynamoTests"
        )
    ]
)
