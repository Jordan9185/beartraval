// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppCore",
    defaultLocalization: "zh-Hant",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        // Domain 模型、規則、API client（App 與 Extension 共用）
        .library(name: "AppCore", targets: ["AppCore"]),
        // SwiftUI 功能頁（只給 App）
        .library(name: "Features", targets: ["Features"]),
        // Share Extension 精簡子集：payload 記錄、ShareDraft
        .library(name: "ShareCore", targets: ["ShareCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/supabase/supabase-swift", from: "2.55.0"),
    ],
    targets: [
        .target(name: "AppCore", dependencies: [.product(name: "Supabase", package: "supabase-swift")]),
        .target(name: "Features", dependencies: ["AppCore", "ShareCore"]),
        .target(name: "ShareCore", dependencies: ["AppCore"]),
        .testTarget(name: "AppCoreTests", dependencies: ["AppCore", "ShareCore"]),
    ]
)
