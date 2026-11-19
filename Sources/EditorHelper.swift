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
    /// The helper's version as packaged in the app, and as installed in an editor (newest copy there).
    static var bundledVersion: String? { package.map { String($0.deletingPathExtension().lastPathComponent.dropFirst("codehatch-helper-".count)) } }
    static func installedVersion(_ e: (id: String, label: String, app: String, cli: String, extensions: String)) -> String? {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder(e).path)) ?? [])
            .filter { $0.lowercased().hasPrefix(id + "-") }.map { String($0.dropFirst(id.count + 1)) }
            .max { $0.compare($1, options: .numeric) == .orderedAscending }
    }
    /// Bring an installed helper up to the version this app carries, in each editor that already has it, so a fix to
    /// the helper reaches people with the app's own update. Editors without it are left alone: that was their choice.
    static func upgradeIfOld() {
        guard let want = bundledVersion else { return }
        for e in present {
            guard let have = installedVersion(e), have.compare(want, options: .numeric) == .orderedAscending else { continue }
            dbg("helper: \(e.label) has \(have), bringing it up to \(want)")
            _ = install(e)
        }
    }

    /// The editor windows the helper has noted: the folders each has open and the shells of its terminals. A window's
    /// note is named after its extension host; one whose host has gone is out of date and removed.
    struct Window { let folders: [String]; let shells: [Int32] }
    static func windows() -> [Window] {
        let dir = Hooks.folder.appendingPathComponent("windows")
        var out: [Window] = []
        for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "json" {
            guard let host = Int32(f.deletingPathExtension().lastPathComponent), kill(host, 0) == 0 else { try? FileManager.default.removeItem(at: f); continue }
            guard let o = (try? Data(contentsOf: f)).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) else { continue }
            out.append(Window(folders: o["folders"] as? [String] ?? [], shells: (o["shells"] as? [Int] ?? []).map { Int32($0) }))
        }
        return out
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
