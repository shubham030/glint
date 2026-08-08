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
        .executableTarget(
            name: "glint",
            dependencies: ["Clibusb", "CGVirtualDisplayShim"]
        ),
    ]
)
