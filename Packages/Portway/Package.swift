// swift-tools-version:5.9
//
// Portway's shared code, used by the app, the packet-tunnel extension and the widgets.
//
// Two libraries on purpose:
//  - PortwayCore has no WireGuardKit dependency. It holds everything that is policy rather than
//    tunnel plumbing — the panel contract, the health rules, usage, the resolver, the pinger —
//    so it can be unit-tested with `swift test` on a Mac without Xcode or the Go bridge, and so
//    the widget extension does not have to link wireguard-go.
//  - PortwayKit adds the wg-quick parser, keychain storage and import, which need WireGuardKit.

import PackageDescription

let package = Package(
    name: "Portway",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PortwayCore", targets: ["PortwayCore"]),
        .library(name: "PortwayKit", targets: ["PortwayKit"]),
    ],
    dependencies: [
        .package(path: "../../Vendor/WireGuardKit"),
    ],
    targets: [
        .target(
            name: "PortwayCore",
            resources: [.process("Resources")]
        ),
        .target(
            name: "PortwayKit",
            dependencies: [
                "PortwayCore",
                .product(name: "WireGuardKit", package: "WireGuardKit"),
            ]
        ),
        .testTarget(
            name: "PortwayCoreTests",
            dependencies: ["PortwayCore"]
        ),
    ]
)
