// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VoiceCapture",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        // C-обёртка над собранной статической библиотекой whisper.cpp.
        // Заголовки лежат в Vendor/install/include, либа — в Vendor/install/lib.
        .target(
            name: "CWhisper",
            path: "Sources/CWhisper",
            linkerSettings: [
                .unsafeFlags([
                    "-LVendor/install/lib",
                    "-lwhisper_combined",
                    "-lc++",
                ]),
                .linkedFramework("Accelerate"),
                .linkedFramework("Foundation"),
            ]
        ),
        .executableTarget(
            name: "VoiceCapture",
            dependencies: ["CWhisper"],
            path: "Sources/VoiceCapture",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Carbon"),
                .linkedFramework("Accelerate"),
            ]
        ),
    ]
)
