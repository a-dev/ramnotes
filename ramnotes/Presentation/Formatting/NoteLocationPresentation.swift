import ramnotesDomain
import AppKit
import Darwin

enum NoteLocationPresentation {
    static func path(_ file: URL) -> String {
        let home = getpwuid(getuid()).map { URL(fileURLWithPath: String(cString: $0.pointee.pw_dir)) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        return path(file, home: home)
    }

    static func path(_ file: URL, home: URL) -> String {
        let path = file.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        let cloudPath = homePath + "/Library/Mobile Documents/com~apple~CloudDocs"
        for (root, label) in [(cloudPath, "iCloud"), (homePath, "~")] {
            if path == root { return label + "/" }
            if path.hasPrefix(root + "/") { return label + String(path.dropFirst(root.count)) }
        }
        return path
    }

    static func failureTitle(_ failure: NoteAccessFailure?) -> String {
        switch failure?.reason {
        case .folderAuthorization: String(localized: "File access required", comment: "Row title for a note whose folder access must be granted again")
        case .staleBookmark: String(localized: "File access required", comment: "Row title for a note whose folder access must be granted again")
        case .missingFile: String(localized: "File not located…", comment: "Row title for a note whose file could not be found")
        case .cloudPlaceholder: String(localized: "Download required", comment: "Row title for a note stored in iCloud that has not been downloaded")
        case .unsupportedEncoding: String(localized: "Unsupported text encoding", comment: "Row title for a note whose text is not valid UTF-8")
        case .unavailableVolume: String(localized: "Storage unavailable", comment: "Row title for a note on a disk or volume that is not connected")
        case .permission: String(localized: "File permission denied", comment: "Row title for a note the app is not allowed to read")
        default: String(localized: "File unavailable…", comment: "Row title for a note whose file cannot be used")
        }
    }

    static func isDefault(_ file: URL, folder: URL) -> Bool {
        file.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path == folder.standardizedFileURL.resolvingSymlinksInPath().path
    }
    static func label(_ file: URL, defaultFolder: URL?) -> String {
        if let defaultFolder, isDefault(file, folder: defaultFolder) { return "default" }
        return path(file)
    }
}
