// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PortalSpike",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "PortalSpike", path: "Sources", exclude: ["portal.png"])]
)
