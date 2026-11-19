import AppKit
import SwiftUI
import Carbon.HIToolbox
import SQLite3
import Sparkle
import ServiceManagement

/// Notes for working out what went wrong, written to a file next to the build.
// Kept out of Documents on purpose: macOS asks for permission before an app touches that folder.
let dbgPath = ProcessInfo.processInfo.environment["CODEHATCH_LOG"] ?? (NSHomeDirectory() + "/Library/Logs/codehatch.log")   // the tests use a log of their own

/// Kept small: once the log passes 1 MB, only its newest 256 KB are kept, so it never grows without end.
let dbgLimit: UInt64 = 1_000_000, dbgKeep = 256_000
func dbg(_ s: String) {
    let line = "\(Date()) \(s)\n"
    if let h = FileHandle(forWritingAtPath: dbgPath) {
        let end = h.seekToEndOfFile()
        h.write(Data(line.utf8)); try? h.close()
        if end > dbgLimit, let data = FileManager.default.contents(atPath: dbgPath) {
            let tail = data.suffix(dbgKeep)
            // Start at a whole line.
            let from = tail.firstIndex(of: UInt8(ascii: "\n")).map { $0 + 1 } ?? tail.startIndex
            try? Data(tail[from...]).write(to: URL(fileURLWithPath: dbgPath), options: .atomic)
        }
    }
    else { try? line.write(toFile: dbgPath, atomically: true, encoding: .utf8) }
}
