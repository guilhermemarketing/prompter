// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Prompter",
    platforms: [.macOS("26.0")],
    dependencies: [
        // Atualizações automáticas (assinadas com EdDSA; o feed fica nas Releases do GitHub).
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "Prompter",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Prompter",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        )
    ],
    swiftLanguageModes: [.v5]
)
