import Foundation
import os

/// One logger per subsystem, all under the bundle ID. Log note IDs and stage names only:
/// never note text or file contents, and mark paths and system error text `.private`.
enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.ramnotes.RAMnotes"
    static let save = Logger(subsystem: subsystem, category: "save")
    static let reconcile = Logger(subsystem: subsystem, category: "reconcile")
    static let move = Logger(subsystem: subsystem, category: "move")
    static let recovery = Logger(subsystem: subsystem, category: "recovery")
    static let access = Logger(subsystem: subsystem, category: "access")
}
