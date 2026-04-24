// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "whisper-transcriber",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "whisper-transcriber",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Sources"
        ),
    ]
)
