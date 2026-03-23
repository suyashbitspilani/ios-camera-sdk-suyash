// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CameraSession",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "CameraSession",
            targets: ["CameraSession"]
        )
    ],
    targets: [
        .target(
            name: "CameraSession",
            dependencies: ["CameraSessionObjC"],
            path: "Sources/CameraSession"
        ),
        .target(
            name: "CameraSessionObjC",
            path: "Sources/CameraSessionObjC",
            publicHeadersPath: "include"
        ),
        .testTarget(
            name: "CameraSessionTests",
            dependencies: ["CameraSession"],
            path: "Tests/CameraSessionTests"
        )
    ]
)
