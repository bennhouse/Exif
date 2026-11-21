// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Exif",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "Exif", path: "Sources/Exif")
    ],
    swiftLanguageModes: [.v5]
)
