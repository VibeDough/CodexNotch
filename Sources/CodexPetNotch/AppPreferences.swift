import AppKit

extension Notification.Name {
    static let notchPreferencesChanged = Notification.Name("CodexPetNotch.preferencesChanged")
}

enum CoexistenceMode: String {
    case automatic
    case alwaysShow
    case menuBarOnly
}

enum AppLanguage: String, CaseIterable {
    case system
    case chinese
    case english

    static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? "") ?? .system
    }

    var usesEnglish: Bool {
        switch self {
        case .chinese: false
        case .english: true
        case .system:
            !(Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") ?? false)
        }
    }

    static func text(_ chinese: String, _ english: String) -> String {
        current.usesEnglish ? english : chinese
    }

    var displayName: String {
        switch self {
        case .system: AppLanguage.text("跟随系统", "System")
        case .chinese: AppLanguage.text("中文", "Chinese")
        case .english: "English"
        }
    }
}

@MainActor
final class AppPreferences {
    private enum Key {
        static let coexistenceMode = "coexistenceMode"
        static let screenNumber = "screenNumber"
    }

    var coexistenceMode: CoexistenceMode {
        get {
            let mode = CoexistenceMode(rawValue: UserDefaults.standard.string(forKey: Key.coexistenceMode) ?? "") ?? .automatic
            return mode == .menuBarOnly ? .automatic : mode
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.coexistenceMode) }
    }

    var selectedScreenNumber: Int? {
        get {
            guard UserDefaults.standard.object(forKey: Key.screenNumber) != nil else { return nil }
            return UserDefaults.standard.integer(forKey: Key.screenNumber)
        }
        set {
            if let newValue { UserDefaults.standard.set(newValue, forKey: Key.screenNumber) }
            else { UserDefaults.standard.removeObject(forKey: Key.screenNumber) }
        }
    }

    func targetScreen() -> NSScreen? {
        guard let selectedScreenNumber, selectedScreenNumber >= 0 else {
            return NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
                ?? NSScreen.main
                ?? NSScreen.screens.first
        }
        return NSScreen.screens.first { screenNumber($0) == selectedScreenNumber }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    func screenNumber(_ screen: NSScreen) -> Int? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue
    }
}
