// swift-tools-version: 5.9
// NOTE: This package does not include MultitouchSupport.framework (private API).
// Use build.sh for full trackpad support.

import PackageDescription

let package = Package(
    name: "Wand",
    platforms: [.macOS(.v11)],
    products: [
        .executable(name: "Wand", targets: ["Wand"])
    ],
    targets: [
        .executableTarget(
            name: "Wand",
            path: ".",
            sources: [
                "main.swift",
                "SiriRemoteApp.swift",
                "MenuBarManager.swift",
                "RemotePanelController.swift",
                "RemoteDetector.swift",
                "RemoteInputHandler.swift",
                "CursorController.swift",
                "MediaKeyInterceptor.swift",
                "AirPodsController.swift",
                "AirPodsStatusHUD.swift",
                "TouchHandler.swift",
                "SystemVolume.swift"
            ],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("Carbon"),
                .linkedFramework("AppKit"),
                .linkedFramework("IOBluetooth")
            ]
        )
    ]
)
