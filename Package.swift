// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "SwiftVCS",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CVCSKit", targets: ["CVCSKit"]),
        .library(name: "CSVNKit", targets: ["CSVNKit"]),
        .executable(name: "vcsctl", targets: ["vcsctl"]),
        .executable(name: "VCSExplorer", targets: ["VCSExplorer"]),
    ],
    targets: [
        .systemLibrary(
            name: "CSVNDependencies",
            pkgConfig: "swiftvcs-svn",
            providers: [.brew(["subversion", "apr", "apr-util", "pkgconf"])]
        ),
        .target(name: "CSVNShim", dependencies: ["CSVNDependencies"]),

        // 后端无关的核心抽象
        .target(name: "CVCSKit"),

        // SVN 后端实现
        .target(name: "CSVNKit", dependencies: ["CVCSKit", "CSVNShim"]),

        // 命令行验证工具
        .executableTarget(
            name: "vcsctl",
            dependencies: ["CVCSKit", "CSVNKit"],
            path: "Tools/vcsctl"
        ),

        // SwiftUI 图形界面
        .executableTarget(
            name: "VCSExplorer",
            dependencies: ["CVCSKit", "CSVNKit"],
            path: "Apps/VCSExplorer",
            exclude: ["Resources"]
        ),

        .executableTarget(
            name: "SwiftVCSChecks",
            dependencies: ["CVCSKit", "CSVNKit", "CSVNShim"],
            path: "Tests/CVCSKitTests"
        ),
    ]
)
