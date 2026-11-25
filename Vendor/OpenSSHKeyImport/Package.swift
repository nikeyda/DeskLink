// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenSSHKeyImport",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "OpenSSHKeyImport", targets: ["OpenSSHKeyImport"])],
    targets: [.target(name: "OpenSSHKeyImport")]
)
