// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Posle",
    platforms: [.macOS("15.0")],
    products: [.executable(name: "Posle", targets: ["PosleApp"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .target(name: "PosleCore"),
        .executableTarget(
            name: "PosleApp",
            dependencies: ["PosleCore", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path"
            ])]
        )
    ]
)
