// swift-tools-version:5.9
import PackageDescription

// KubaCore: lógica do app sem dependência de iOS (protocolo, EQ, firmware).
// Compila em macOS, iOS e Linux para que os testes rodem no CI.
let package = Package(
    name: "KubaCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "KubaCore", targets: ["KubaCore"]),
    ],
    targets: [
        .target(name: "KubaCore"),
        .testTarget(
            name: "KubaCoreTests",
            dependencies: ["KubaCore"]
        ),
    ]
)
