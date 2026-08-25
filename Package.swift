// swift-tools-version: 6.1
import PackageDescription

// 胶囊清单：新增能力 = 在此追加一个名字 + 建 Sources/Pods/<名>/ 目录（BG-11 增量累加的唯一显式点）
let pods: [String] = ["DirectoryReader", "Transfer", "PathComplete"]

let podTargets: [Target] = pods.map {
    .target(name: $0, dependencies: ["NSpaceContracts"], path: "Sources/Pods/\($0)")
}
let podTestTargets: [Target] = pods.map {
    .testTarget(name: "\($0)Tests", dependencies: [.target(name: $0), "NSpaceContracts"])
}
let podDeps: [Target.Dependency] = pods.map { .target(name: $0) }

let package = Package(
    name: "NSpace",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "NSpace", targets: ["NSpaceApp"]),
        .executable(name: "nspace-probe", targets: ["NSpaceProbe"]),
    ],
    targets: [
        .target(name: "NSpaceContracts"),
        .target(name: "NSpaceKernel", dependencies: ["NSpaceContracts"]),
        .executableTarget(
            name: "NSpaceApp",
            dependencies: ["NSpaceKernel", "NSpaceContracts"] + podDeps
        ),
        .executableTarget(
            name: "NSpaceProbe",
            dependencies: ["NSpaceKernel", "NSpaceContracts"] + podDeps
        ),
        .testTarget(name: "NSpaceKernelTests", dependencies: ["NSpaceKernel", "NSpaceContracts"]),
    ] + podTargets + podTestTargets
)
