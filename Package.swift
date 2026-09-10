// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NotchNotes",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "NotchNotes",
            path: "Sources/NotchNotes"
        )
    ]
)
