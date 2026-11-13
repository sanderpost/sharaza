// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sharaza",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Sharaza", targets: ["SharazaApp"]),
        .library(name: "SharazaKit", targets: ["SharazaKit"]),
    ],
    targets: [
        .target(
            name: "CSharazaFFI",
            path: "Sources/CSharazaFFI",
            publicHeadersPath: "include"
        ),
        .target(
            name: "SharazaKit",
            dependencies: ["CSharazaFFI"],
            path: "Sources/SharazaKit",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                // Force the static archive. -lsharaza_ffi prefers the cdylib and
                // records an absolute path that only exists on the build machine.
                .unsafeFlags([
                    "-Xlinker", "-force_load",
                    "-Xlinker", "../target/release/libsharaza_ffi.a",
                ]),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Vision"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreImage"),
                .linkedFramework("ImageIO"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("Security"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        .executableTarget(
            name: "SharazaApp",
            dependencies: ["SharazaKit"],
            path: "Sources/SharazaApp",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "SharazaTests",
            dependencies: ["SharazaKit"],
            path: "Tests/SharazaTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
    ]
)
