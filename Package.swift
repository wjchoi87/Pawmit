// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Pawmit",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Pawmit", targets: ["Pawmit"]),
        // 대소문자 구분 없는 APFS에서 앱(Pawmit)과 충돌하지 않도록 CLI 제품명은 pawmit-cli.
        // 설치 시 ~/.pawmit/bin/pawmit 으로 복사된다.
        .executable(name: "pawmit-cli", targets: ["PawmitCLI"]),
        .library(name: "PawmitCore", targets: ["PawmitCore"]),
    ],
    targets: [
        // 에이전트 hook 포맷 변환, socket wire protocol, 설정 설치 등 UI와 무관한 로직
        .target(
            name: "PawmitCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // 에이전트 hook이 실행하는 짧은 CLI (`pawmit hook <agent> <event>`)
        .executableTarget(
            name: "PawmitCLI",
            dependencies: ["PawmitCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // 메뉴바 + 데스크탑 펫 앱
        .executableTarget(
            name: "Pawmit",
            dependencies: ["PawmitCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PawmitCoreTests",
            dependencies: ["PawmitCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
