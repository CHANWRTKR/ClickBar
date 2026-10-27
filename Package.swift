// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClickBar",
    platforms: [.macOS("27.0")],
    targets: [
        .target(name: "MenuBarShim"),
        .target(name: "ClickBarCore", dependencies: ["MenuBarShim"]),
        .executableTarget(name: "ClickBar", dependencies: ["ClickBarCore"]),
        .executableTarget(name: "ClickBarTests", dependencies: ["ClickBarCore"]),
    ]
)
