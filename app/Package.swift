// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "codehatch",
    platforms: [.macOS(.v14)],
    // Sparkle: the updater most Mac apps outside the App Store use. It checks a feed on codehatch.ai for a newer
    // version, verifies its signature, and installs it.
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")],
    targets: [.executableTarget(name: "codehatch", dependencies: [.product(name: "Sparkle", package: "Sparkle")], path: "Sources", exclude: ["portal.png"])]
)
