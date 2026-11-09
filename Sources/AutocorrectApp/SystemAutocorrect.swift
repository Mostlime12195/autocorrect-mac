import Foundation

/// macOS's own "Correct spelling automatically" (global domain, current user). Keylime turns it off so the two don't
/// fight; apps read it at launch, so already-open apps may need a restart.
enum SystemAutocorrect {
    static let keys = ["NSAutomaticSpellingCorrectionEnabled", "WebAutomaticSpellingCorrectionEnabled"]

    /// on unless the user (or Keylime) turned it off; missing = the system default, on
    static var isOn: Bool {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        let v = CFPreferencesCopyValue(keys[0] as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return (v as? Bool) ?? ((v as? NSNumber)?.boolValue ?? true)
    }

    static func set(_ on: Bool) {
        for k in keys {
            CFPreferencesSetValue(k as CFString, on ? kCFBooleanTrue : kCFBooleanFalse, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
}
