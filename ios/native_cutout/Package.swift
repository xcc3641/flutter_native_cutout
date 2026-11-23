import PackageDescription

let package = Package(
    name: "native_cutout",
    platforms: [
        .iOS("13.0"),
    ],
    products: [
        .library(name: "native-cutout", targets: ["native_cutout"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "native_cutout",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            resources: [
                .process("PrivacyInfo.xcprivacy"),
            ]
        )
    ]
)
