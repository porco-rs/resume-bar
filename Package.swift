// swift-tools-version: 6.2
// Resume Bar: one Swift package for the whole app (curtain principle).
// Every module is declared here up front.
import PackageDescription

let package = Package(
    name: "ResumeBar",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "ResumeBar", targets: ["ResumeBar"]),
        .library(name: "RBServer", targets: ["RBServer"]),
        .executable(name: "rb", targets: ["rb"]),
    ],
    targets: [
        // Shared models and service protocols.
        .target(name: "RBContract"),
        // zstd 1.5.7 decompression (vendored C, BSD-3-Clause) for Codex rollout-*.jsonl.zst.
        .target(name: "CZstd", path: "Sources/CZstd",
                exclude: ["LICENSE", "VENDOR.txt"],
                cSettings: [.define("ZSTD_LEGACY_SUPPORT", to: "0"), .define("ZSTD_DISABLE_ASM", to: "1"),
                            .unsafeFlags(["-Wno-everything"])]),
        // Reads Claude Code and Codex session files, resolves projects, watches folders.
        .target(name: "RBIndex", dependencies: ["RBContract", "CZstd"]),
        // Detects running claude/codex processes, session end, resume counts.
        .target(name: "RBLive", dependencies: ["RBContract"]),
        // SQLite for user fields and settings, migrations, undo stack.
        .target(name: "RBStore", dependencies: ["RBContract"],
                linkerSettings: [.linkedLibrary("sqlite3")]),
        // Opens, focuses and closes Ghostty and Terminal.app windows.
        .target(name: "RBTerminal", dependencies: ["RBContract"]),
        // Frontmost context, selected text, permissions, hotkeys (AppKit, Accessibility).
        .target(name: "RBPlatform", dependencies: ["RBContract"]),
        // UI state, key handling, HTML templates from the prototype.
        .target(name: "RBUI", dependencies: ["RBContract"]),
         .target(name: "RBServer", dependencies: ["RBContract", "RBLive"]),
        .executableTarget(name: "rb", dependencies: ["RBContract"]),
        // Composes services, executes intents, renders fragments.
        .target(name: "RBEngine", dependencies: [
            "RBContract", "RBIndex", "RBLive", "RBStore", "RBTerminal", "RBPlatform", "RBUI", "RBServer",
        ]),
        // AppKit shell: status item, popover, panel, settings window, WKWebView host.
        .executableTarget(name: "ResumeBar", dependencies: ["RBEngine", "RBServer"]),

        .testTarget(name: "RBServerTests", dependencies: ["RBServer", "RBContract", "RBLive"]),
        .testTarget(name: "RBContractTests", dependencies: ["RBContract"]),
        .testTarget(name: "RBIndexTests", dependencies: ["RBIndex"], exclude: ["Samples"]),
        .testTarget(name: "RBLiveTests", dependencies: ["RBLive"]),
        .testTarget(name: "RBStoreTests", dependencies: ["RBStore"]),
        .testTarget(name: "RBTerminalTests", dependencies: ["RBTerminal"]),
        .testTarget(name: "RBPlatformTests", dependencies: ["RBPlatform"]),
        .testTarget(name: "RBUITests", dependencies: ["RBUI"]),
        .testTarget(name: "RBEngineTests", dependencies: ["RBEngine"]),
    ]
)
