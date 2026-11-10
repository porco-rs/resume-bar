import Foundation
import ServiceManagement
import os

// Serializes startup and onboarding callbacks so registration is attempted at most once.
actor LoginItem {
    static let shared = LoginItem()
    private let attemptedKey = "loginItemRegistrationAttempted"
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ResumeBar", category: "login-item")

    // Accept bundles inside /Applications or ~/Applications, including nested bundles and
    // symlinks resolving there; reject development paths, prefix lookalikes, and symlinks out.
    static func isInstalledApp(_ bundleURL: URL, homeDirectory: URL) -> Bool {
        let bundleComponents = bundleURL.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let applicationDirectories = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            homeDirectory.appendingPathComponent("Applications", isDirectory: true),
        ]
        return applicationDirectories.contains { directory in
            let components = directory.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            return bundleComponents.count > components.count && bundleComponents.starts(with: components)
        }
    }

    func registerIfNeeded() {
        let args = CommandLine.arguments
        guard !["--fixture", "--show", "--snapshot"].contains(where: args.contains),
              Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL",
              Bundle.main.bundleIdentifier != nil,
              Self.isInstalledApp(Bundle.main.bundleURL, homeDirectory: FileManager.default.homeDirectoryForCurrentUser),
              UserDefaults.standard.bool(forKey: "onboarded"),
              !UserDefaults.standard.bool(forKey: attemptedKey) else { return }

        // Record the attempt before calling the service: later removal or denial is the user's choice.
        UserDefaults.standard.set(true, forKey: attemptedKey)
        guard SMAppService.mainApp.status == .notRegistered else { return }
        do {
            try SMAppService.mainApp.register()
        } catch {
            log.error("Login item registration failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
