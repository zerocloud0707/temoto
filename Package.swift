// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Temoto",
    platforms: [.macOS(.v14)],
    targets: [
        // 純ロジック層。AppKit非依存にして自前ランナーからテストできるようにする
        .target(
            name: "TemotoCore",
            path: "Sources/TemotoCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // アプリ本体（メニューバー常駐・LSUIElement）
        .executableTarget(
            name: "Temoto",
            dependencies: ["TemotoCore"],
            path: "Sources/Temoto",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // 自前テストランナー（Command Line ToolsのみでXCTest/Testingが無い環境向け）
        // 実行: swift run TemotoChecks
        .executableTarget(
            name: "TemotoChecks",
            dependencies: ["TemotoCore"],
            path: "Sources/TemotoChecks",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
