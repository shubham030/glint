// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "glint",
    platforms: [.macOS(.v13)],
    targets: [
        .systemLibrary(
            name: "Clibusb",
            pkgConfig: "libusb-1.0",
            providers: [.brew(["libusb"])]
        ),
        .target(
            name: "CGVirtualDisplayShim",
            linkerSettings: [.linkedFramework("CoreGraphics")]
        ),
        // Platform-neutral wire format, tiling and RLE — unit-tested without
        // a device, and the reference the Go host mirrors.
        .target(name: "GlintCore"),
        .executableTarget(
            name: "glint",
            dependencies: ["Clibusb", "CGVirtualDisplayShim", "GlintCore"]
        ),
        .testTarget(name: "GlintCoreTests", dependencies: ["GlintCore"]),
    ]
)
