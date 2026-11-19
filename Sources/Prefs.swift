import AppKit
import SwiftUI
import Carbon.HIToolbox
import SQLite3
import Sparkle
import ServiceManagement

enum Prefs {
    static let defaults: [String: Any] = [
        "openOnHover": true, "hotkey": "opt-space", "showLastMessage": true, "showRecent": true, "recentDays": 14,
        "widgetOnTop": false, "confirmClose": true, "reopenIn": "auto", "demoMode": false, "hiddenRepos": "", "notchOrder": "recent", "liveUpdates": false, "showBeacon": true, "beaconShows": "orb", "windowLook": "system",
        "showMenuIcon": true, "widgetLayout": "cards", "widgetGroup": "state", "widgetFilter": "all", "didSetup": false,
    ]
    static func register() { UserDefaults.standard.register(defaults: defaults) }
    static func bool(_ k: String) -> Bool { UserDefaults.standard.bool(forKey: k) }
    static func string(_ k: String) -> String { UserDefaults.standard.string(forKey: k) ?? "" }
    static func int(_ k: String) -> Int { UserDefaults.standard.integer(forKey: k) }
    /// Repo names that are never shown, lower-cased. Added one at a time in settings and stored one per line.
    static var hiddenRepos: Set<String> {
        Set(string("hiddenRepos").lowercased().split(whereSeparator: { $0 == "," || $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }
    /// The shortcuts on offer: a label, the key and the modifier keys.
    static let hotkeys: [(id: String, label: String, key: Int, mods: Int)] = [
        ("opt-space", "⌥ Space", kVK_Space, optionKey), ("ctrl-space", "⌃ Space", kVK_Space, controlKey),
        ("opt-shift-space", "⌥ ⇧ Space", kVK_Space, optionKey | shiftKey), ("cmd-shift-space", "⌘ ⇧ Space", kVK_Space, cmdKey | shiftKey),
        ("ctrl-opt-space", "⌃ ⌥ Space", kVK_Space, controlKey | optionKey), ("none", "None", 0, 0),
    ]
    static let editors: [(id: String, label: String, app: String, scheme: String)] = [
        ("cursor", "Cursor", "/Applications/Cursor.app", "cursor"), ("vscode", "VS Code", "/Applications/Visual Studio Code.app", "vscode"),
        ("windsurf", "Windsurf", "/Applications/Windsurf.app", "windsurf"), ("vscodium", "VSCodium", "/Applications/VSCodium.app", "vscodium"),
    ]
}
