// swift-tools-version: 5.9
import PackageDescription

// Test harness for the platform-neutral logic shared by the macOS app, the iOS
// companion app, and the keyboard extension. The shipping products are built from
// TalkType.xcodeproj — this package exists so `swift test` can verify the pure
// logic from the command line, without Xcode and without a device.
//
// Sources are referenced in place; this package must not become a second build
// system. Only files that compile on every Apple platform belong here.
let package = Package(
    name: "TalkTypeCore",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "TalkTypeCore",
            path: "TalkType",
            exclude: [
                "Assets.xcassets",
                "DictationManager.swift",
                "HotkeyManager.swift",
                "HotkeySettingsWindow.swift",
                "Info.plist",
                "OverlayWindow.swift",
                "STTKeyStore.swift",
                "SetupWindow.swift",
                "TalkType.entitlements",
                "TalkTypeApp.swift",
            ],
            sources: [
                "AppIdentity.swift",
                "AudioDevices.swift",
                "AudioRecorder.swift",
                "Config.swift",
                "ElevenLabsSTTClient.swift",
                "GrokSTTClient.swift",
                "Log.swift",
                "OpenAISTTClient.swift",
                "STTClient.swift",
                "STTProvider.swift",
                "SonioxSTTClient.swift",
                "TextInserter.swift",
                "VocabularyStore.swift",
                "WAVEncoder.swift",
            ]
        ),
        .testTarget(
            name: "TalkTypeCoreTests",
            dependencies: ["TalkTypeCore"],
            path: "Tests/TalkTypeCoreTests"
        ),
    ]
)
