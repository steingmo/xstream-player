// swift-tools-version:5.9
import PackageDescription

// SwiftPM pulls in Sparkle (updates) and MPVKit (embedded libmpv player). The bundle
// itself is still assembled by build.sh / release.sh, which is why the sources stay in
// Sources/ rather than moving into a per-target directory.
let package = Package(
    name: "Xstream",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        .package(url: "https://github.com/mpvkit/MPVKit", exact: "1.1.0-n9.0.2"),
    ],
    targets: [
        .executableTarget(
            name: "Xstream",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "MPVKit", package: "MPVKit"),
            ],
            path: "Sources"),
    ]
)
