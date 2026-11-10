import Foundation

public enum AppLanguage: String, Sendable, CaseIterable {
    case en, de

    public static let current = resolve(
        override: ProcessInfo.processInfo.environment["RB_LANGUAGE"],
        preferred: Locale.preferredLanguages,
        underTest: Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
    )

    public static func resolve(override: String?, preferred: [String], underTest: Bool) -> AppLanguage {
        if let override, let language = AppLanguage(rawValue: override) { return language }
        if underTest { return .de }
        for preference in preferred {
            let code = preference.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)?.lowercased()
            if let code, let language = AppLanguage(rawValue: code) { return language }
        }
        return .en
    }
}
