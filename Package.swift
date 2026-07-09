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
        .executableTarget(
            name: "Dynamo",
            path: "Sources/Dynamo",
            exclude: ["Info.plist"],
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                // Embed Info.plist so permission usage strings are present when
                // launching the bare executable (SPM has no .app bundle by default).
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/Dynamo/Info.plist"
                ], .when(platforms: [.macOS]))
            ]
        )
    ]
)
