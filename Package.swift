// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeAccountSwitcher",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "ClaudeAccountSwitcher", targets: ["ClaudeAccountSwitcherApp"])],
    targets: [
        .target(name: "ClaudeAccountSwitcherCore", path: "Sources/ClaudeAccountSwitcherCore"),
        .executableTarget(name: "ClaudeAccountSwitcherApp", dependencies: ["ClaudeAccountSwitcherCore"], path: "Sources/ClaudeAccountSwitcherApp", resources: [.copy("../../Resources")]),
        .executableTarget(name: "ClaudeAccountSwitcherTests", dependencies: ["ClaudeAccountSwitcherCore"], path: "Tests/ClaudeAccountSwitcherTests")
    ]
)
