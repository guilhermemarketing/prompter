// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Prompter",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "Prompter", path: "Sources/Prompter")
    ],
    swiftLanguageModes: [.v5]
)
