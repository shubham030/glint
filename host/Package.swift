// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "vdisp",
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
            name: "vdisp",
            dependencies: ["Clibusb", "CGVirtualDisplayShim"]
        ),
    ]
)
