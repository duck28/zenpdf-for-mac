// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ZenPDF",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ZenPDF",
            path: "Sources/ZenPDF"
        ),
        .testTarget(
            name: "ZenPDFTests",
            dependencies: ["ZenPDF"],
            path: "Tests/ZenPDFTests"
        ),
    ]
)
