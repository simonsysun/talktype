// swift-tools-version: 5.9
import PackageDescription

// Test harness for the macOS app's platform-neutral logic. The shipping app is
// built from TalkType.xcodeproj — this package exists so `swift test` can verify
// the pure logic from the command line, without Xcode.
//
// Sources are referenced in place; this package must not become a second build
// system. Only files that compile without AppKit UI / Keychain belong here.
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
                "TalkType.entitlements",
                "TalkTypeApp.swift",
            ],
            sources: [
                "AppIdentity.swift",
                "AudioDevices.swift",
                "AudioRecorder.swift",
                "Config.swift",
                "DoubaoSTTClient.swift",
                "GrokSTTClient.swift",
                "Log.swift",
                "STTClient.swift",
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
