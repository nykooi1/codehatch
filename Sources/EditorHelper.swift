import AppKit
import SwiftUI
import Carbon.HIToolbox
import SQLite3
import Sparkle
import ServiceManagement

/// Every choice in the settings window, with its default. Read straight from here wherever it matters.
/// The editor helper: a small extension for Cursor, VS Code and editors built on it. It lets codehatch bring the right
/// terminal tab forward and reopen a session in the right project. It travels inside the app and is installed with
/// the editor's own command-line tool, the same way "Install from VSIX" does.
enum Helper {
    static let id = "codehatch.codehatch-helper"
    static let editors: [(id: String, label: String, app: String, cli: String, extensions: String)] = [
        ("cursor", "Cursor", "/Applications/Cursor.app", "Contents/Resources/app/bin/cursor", ".cursor/extensions"),
        ("vscode", "VS Code", "/Applications/Visual Studio Code.app", "Contents/Resources/app/bin/code", ".vscode/extensions"),
        ("windsurf", "Windsurf", "/Applications/Windsurf.app", "Contents/Resources/app/bin/windsurf", ".windsurf/extensions"),
        ("vscodium", "VSCodium", "/Applications/VSCodium.app", "Contents/Resources/app/bin/codium", ".vscode-oss/extensions"),
    ]
    /// The editors on this Mac.
    static var present: [(id: String, label: String, app: String, cli: String, extensions: String)] {
        editors.filter { FileManager.default.fileExists(atPath: $0.app + "/" + $0.cli) }
    }
    /// The helper as packaged inside the app.
    static var package: URL? { Bundle.main.urls(forResourcesWithExtension: "vsix", subdirectory: nil)?.sorted { $0.lastPathComponent < $1.lastPathComponent }.last }
    /// For the tests: install into this folder instead of the editor's own.
    static var folderOverride: String? { ProcessInfo.processInfo.environment["CODEHATCH_HELPER_DIR"] }
    static func folder(_ e: (id: String, label: String, app: String, cli: String, extensions: String)) -> URL {
        folderOverride.map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(e.extensions)
    }
    static func installed(_ e: (id: String, label: String, app: String, cli: String, extensions: String)) -> Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder(e).path)) ?? []).contains { $0.lowercased().hasPrefix(id + "-") }
    }
    /// Install it. Returns nil when it is in place afterwards, or a sentence saying what went wrong.
    static func install(_ e: (id: String, label: String, app: String, cli: String, extensions: String)) -> String? {
        guard let package else { return "The helper is missing from this copy of codehatch." }
        var args = ["--install-extension", package.path, "--force"]
        if let folderOverride { args += ["--extensions-dir", folderOverride] }
        let out = Codex.shell(e.app + "/" + e.cli, args)
        dbg("helper: install in \(e.label): \(out.trimmingCharacters(in: .whitespacesAndNewlines).suffix(120))")
        return installed(e) ? nil : "\(e.label) did not accept the helper."
    }
}
