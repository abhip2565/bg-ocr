// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "BGOCRProcessor",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "BGOCRProcessor",
            targets: ["BGOCRProcessor"]
        ),
        .library(
            name: "BGOCRProcessorRN",
            targets: ["BGOCRProcessorRN"]
        ),
    ],
    targets: [
        .target(
            name: "BGOCRProcessor",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .target(
            name: "BGOCRProcessorRN",
            dependencies: ["BGOCRProcessor"]
        ),
        .testTarget(
            name: "BGOCRProcessorTests",
            dependencies: ["BGOCRProcessor"]
        ),
    ]
)
