import AppKit
import SwiftUI
import Carbon.HIToolbox
import SQLite3
import Sparkle
import ServiceManagement

/// Notes for working out what went wrong, written to a file next to the build.
// Kept out of Documents on purpose: macOS asks for permission before an app touches that folder.
let dbgPath = NSHomeDirectory() + "/Library/Logs/codehatch.log"

func dbg(_ s: String) {
    let line = "\(Date()) \(s)\n"
    if let h = FileHandle(forWritingAtPath: dbgPath) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
    else { try? line.write(toFile: dbgPath, atomically: true, encoding: .utf8) }
}
