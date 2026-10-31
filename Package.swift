// swift-tools-version: 5.10
import PackageDescription

// The portable graph must resolve without downloading a macOS binary SDK.
// Additional platform clients add their own adapter and application targets.
var dependencies: [Package.Dependency] = []
var products: [Product] = []
var targets: [Target] = [
    .target(name: "AfterCore"),
    .target(name: "AfterPlatform", dependencies: ["AfterCore"]),
    .target(name: "AfterLocalization", resources: [.process("Resources")]),
    .testTarget(
        name: "AfterCoreTests", dependencies: ["AfterCore"], path: "Tests",
        exclude: ["UpdateFixture.swift", "AfterPlatformTests"],
        sources: ["CoreChecks.swift", "CalendarLayoutChecks.swift", "TaskDueDateChecks.swift", "AssistantReadChecks.swift"]
    ),
    .testTarget(name: "AfterPlatformTests", dependencies: ["AfterPlatform", "AfterLocalization"])
]

#if os(macOS)
dependencies.append(.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"))
products.append(.executable(name: "After", targets: ["AfterApp"]))
targets += [
    .target(name: "AfterPlatformMacOS", dependencies: ["AfterCore", "AfterPlatform", "AfterLocalization"]),
    .executableTarget(
        name: "AfterApp",
        dependencies: ["AfterCore", "AfterPlatform", "AfterPlatformMacOS", "AfterLocalization", .product(name: "Sparkle", package: "Sparkle")],
        exclude: ["Resources"],
        linkerSettings: [.unsafeFlags([
            "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
            "-Xlinker", "-rpath", "-Xlinker", "@executable_path"
        ])]
    )
]
#endif

let package = Package(name: "After", platforms: [.macOS("15.0")], products: products,
                      dependencies: dependencies, targets: targets)
