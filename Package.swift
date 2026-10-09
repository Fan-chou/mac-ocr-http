// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacOcrHttp",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "mac-ocr-http", targets: ["MacOcrHttp"]),
        .executable(name: "mac-ocr-line-merge-tests", targets: ["LineMergeTestRunner"]),
    ],
    targets: [
        .target(
            name: "LineMergeCore"
        ),
        .executableTarget(
            name: "MacOcrHttp",
            dependencies: ["LineMergeCore"],
            swiftSettings: [
                .define("OCR_HTTP_HAS_DOCUMENT_LAYOUT"),
            ],
            linkerSettings: [
                .linkedFramework("Vision"),
                .linkedFramework("ImageIO"),
                .linkedFramework("CoreGraphics"),
            ]
        ),
        .executableTarget(
            name: "LineMergeTestRunner",
            dependencies: ["LineMergeCore"]
        ),
    ]
)
