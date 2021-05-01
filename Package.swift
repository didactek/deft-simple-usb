// swift-tools-version:5.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

// Tools version 5.3 is required for the "condition: .when(platforms:)" syntax
// in dependencies. The library will build with older versions if the dependencies
// are hardcoded.

// NOTE: work is needed to avoid warnings/errors in LibUSB/HostFWUSB on the
// platforms that aren't using them.
//
// FIXME: A better solution is needed.
//
// The Package.swift syntax doesn't offer a condition option for a target,
// so it is always built on all platforms--even when it should only be
// built if it is a dependency of another required component.
//
// See https://bugs.swift.org/browse/SR-13093
//
// For platforms where the library (or in the case of HostFWUSB, the framework)
// is not present, the unconditional build will cause build errors.
// To prevent these, all code in the LibUSB and HostFWUSB modules is wrapped
// with a "#if SKIPMODULE" guard. The swiftSettings option sets this define
// on platforms that don't use the module. The SKIPMODULE pattern is
// awkward but effective in preventing spurious/harmless build errors.
//
// The build of a target on platforms that don't need/use it also produces warnings:
//   warning: failed to retrieve search paths with pkg-config; maybe pkg-config is not installed
//   warning: you may be able to install libusb-1.0 using your system-packager: brew install libusb
// By making the dependency on the systemLibrary conditional
//   .target(name: "CLibUSB", condition: .when(platforms: [.linux])),
// these warnings could be squelched in the command-line build, but not in Xcode (12.5).
// We currently favor the simplicity of the common target description over the
// brittleness (because of platform) that would come with cleaning up warnings in
// only one build environment.
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

            dependencies: [
                "CLibUSB",
                "SimpleUSB",
                .product(name: "Logging", package: "swift-log")],
            swiftSettings: [.define("SKIPMODULE", .when(platforms: [.macOS]))]),
        .target(
            name: "HostFWUSB",
            dependencies: ["SimpleUSB", .product(name: "Logging", package: "swift-log")],
            swiftSettings: [.define("SKIPMODULE", .when(platforms: [.linux]))]),
        .target(
            name: "PortableUSB",
            dependencies: [
                .target(name: "HostFWUSB", condition: .when(platforms: [.macOS])),
                .target(name: "LibUSB", condition: .when(platforms: [.linux])),
            ],
            swiftSettings: [
                .define("USE_LIBUSB", .when(platforms: [.linux])),
                .define("USE_FWUSB", .when(platforms: [.macOS]))
            ]),
        .target(
            name: "SimpleUSB",
            dependencies: []),
        // FIXME: this generates a warning on macOS, even though the library is not needed
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
