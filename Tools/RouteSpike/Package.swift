// swift-tools-version: 6.2
import PackageDescription

// S1 路線／POI 實測工具（issue #1）。在 macOS 上直接呼叫 MapKit，與 iOS 裝置端 MKDirections 同一套服務。
let package = Package(
    name: "RouteSpike",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "RouteSpike"),
    ]
)
