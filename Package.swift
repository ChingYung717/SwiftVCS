// swift-tools-version: 5.9
import PackageDescription
import Foundation

// 自动识别 Apple Silicon (/opt/homebrew) 与 Intel (/usr/local) 的 Homebrew 安装前缀
let brewPrefix = FileManager.default.fileExists(atPath: "/opt/homebrew/opt/subversion")
    ? "/opt/homebrew"
    : "/usr/local"
let svnHome = brewPrefix + "/opt/subversion"
let svnInc = svnHome + "/include/subversion-1"
let svnLib = svnHome + "/lib"
let aprInc = brewPrefix + "/opt/apr/include/apr-1"
let aprLib = brewPrefix + "/opt/apr/lib"

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
        // libsvn 的 C 封装
        .target(
            name: "CSVNShim",
            cSettings: [
                .headerSearchPath("include"),
                .unsafeFlags(["-Wno-deprecated-declarations"]),
                .unsafeFlags(["-I" + svnInc, "-I" + svnHome + "/include", "-I" + aprInc]),
            ],
            linkerSettings: [
                // 注意：-L 必须排在 -l 之前，SwiftPM 的 linkedLibrary 会排在 unsafeFlags 之前，
                // 因此这里统一用 unsafeFlags 显式控制顺序。
                .unsafeFlags([
                    "-L" + svnLib,
                    "-L" + aprLib,
                    "-lsvn_client-1",
                    "-lsvn_ra-1",
                    "-lsvn_ra_serf-1",
                    "-lsvn_ra_svn-1",
                    "-lsvn_subr-1",
                    "-lsvn_wc-1",
                    "-lsvn_diff-1",
                    "-lsvn_delta-1",
                    "-lsvn_fs-1",
                    "-lsvn_fs_util-1",
                    "-lapr-1",
                    "-laprutil-1",
                    "-Xlinker", "-rpath", "-Xlinker", svnLib,
                    "-Xlinker", "-rpath", "-Xlinker", aprLib,
                    "-Xlinker", "-w",
                ])
            ]
        ),

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

        .testTarget(name: "CVCSKitTests", dependencies: ["CVCSKit", "CSVNKit"]),
    ]
)
