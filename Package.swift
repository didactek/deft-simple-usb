// swift-tools-version:5.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

// Tools version 5.3 is required for the "condition: .when(platforms:)" syntax
// in dependencies. The library will build with older versions if the dependencies
// are hardcoded.

import PackageDescription

let package = Package(
    name: "deft-simple-usb",
    products: [
        // Products define the executables and libraries produced by a package, and make them visible to other packages.
        .library(
            name: "LibUSB",
            targets: ["LibUSB"]),
        .library(
            name: "HostFWUSB",
            targets: ["HostFWUSB"]),
        .library(
            name: "SimpleUSB",
            targets: ["SimpleUSB"]),
        .library(
            name: "PortableUSB",
            targets: ["PortableUSB"]),
        .library(
            name: "CLibUSB",
            targets: ["CLibUSB"]),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages which this package depends on.
        .target(
            name: "LibUSB",
            dependencies: ["CLibUSB", "SimpleUSB", .product(name: "Logging", package: "swift-log")]),
        .target(
            name: "HostFWUSB",
            dependencies: ["SimpleUSB", .product(name: "Logging", package: "swift-log")]),
        .target(
            name: "PortableUSB",
            dependencies: [
                .target(name: "HostFWUSB", condition: .when(platforms: [.macOS])),
                .target(name: "LibUSB", condition: .when(platforms: [.linux])),
            ]),
        .target(
            name: "SimpleUSB",
            dependencies: []),
        .systemLibrary(
            name: "CLibUSB",
            pkgConfig: "libusb-1.0",
            providers: [
                .brew(["libusb"]),
                .apt(["libusb-1.0-0-dev"]),
            ]
        ),
        .testTarget(
            name: "ftdi-synchronous-serialTests",
            dependencies: ["LibUSB"]),
    ]
)
