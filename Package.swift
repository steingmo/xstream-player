// swift-tools-version:5.9
import PackageDescription

// SwiftPM is here for one reason: Sparkle. The bundle itself is still assembled by
// build.sh / release.sh, which is why the sources stay in Sources/ rather than moving
// into a per-target directory.
let package = Package(
    name: "Xstream",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "Xstream",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources"),
    ]
)
