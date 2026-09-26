import Foundation

/// Manages security-scoped bookmark access for the user-chosen save directory.
/// In sandbox mode, a raw file path is not enough — we need a bookmark that the
/// system can resolve to regrant access across app launches.
enum SaveDirectoryAccess {

    private static let bookmarkKey = "saveDirectoryBookmark"
    private static let pathKey = "saveDirectory"

    /// The user's real `~/Downloads`. In the sandbox `NSHomeDirectory()` and
    /// `.downloadsDirectory` point into the app container, so the real home is
    /// read from the user database. Writable without a bookmark thanks to the
    /// `files.downloads.read-write` entitlement.
    static var defaultDirectory: URL {
        let home = getpwuid(getuid()).flatMap { String(cString: $0.pointee.pw_dir) }
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        return URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("Downloads", isDirectory: true)
    }

    /// Save both the path (for display) and the security-scoped bookmark (for sandbox access).
    static func save(url: URL) {
        UserDefaults.standard.set(url.path, forKey: pathKey)
        if let bookmark = try? url.bookmarkData(options: .withSecurityScope,
                                                  includingResourceValuesForKeys: nil,
                                                  relativeTo: nil) {
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
        } else {
            // Bookmark creation failed — clear any stale bookmark so we don't
            // keep granting access to an old folder that no longer matches path.
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
        }
    }

    /// Resolve the configured save directory, starting sandbox-scoped access,
    /// but return `nil` when no valid security-scoped bookmark exists. Use this
    /// for writes that must succeed in the sandbox — `nil` means the caller
    /// should prompt the user to choose a folder. Until the user picks a folder,
    /// this is `~/Downloads` (when it is writable).
    /// Caller **must** call `stopAccessing(url:)` when done writing.
    static func resolveIfAccessible() -> URL? {
        guard let bookmarkData = UserDefaults.standard.data(forKey: bookmarkKey) else {
            guard UserDefaults.standard.string(forKey: pathKey) == nil,
                  FileManager.default.isWritableFile(atPath: defaultDirectory.path) else { return nil }
            return defaultDirectory
        }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmarkData,
                                  options: .withSecurityScope,
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &isStale) else { return nil }
        guard url.startAccessingSecurityScopedResource() else { return nil }
        // Re-creating a security-scoped bookmark requires active scoped access,
        // so this has to come after startAccessing — doing it before meant the
        // refresh always failed and the bookmark stayed stale on every save.
        if isStale {
            if let fresh = try? url.bookmarkData(options: .withSecurityScope,
                                                  includingResourceValuesForKeys: nil,
                                                  relativeTo: nil) {
                UserDefaults.standard.set(fresh, forKey: bookmarkKey)
            }
        }
        return url
    }

    /// Resolve the directory URL **without** starting scoped access.
    /// Use this for NSSavePanel/NSOpenPanel `directoryURL` hints — they handle
    /// their own sandbox access via powerbox.
    static func directoryHint() -> URL? {
        if let path = UserDefaults.standard.string(forKey: pathKey) {
            return URL(fileURLWithPath: path)
        }
        return defaultDirectory
    }

    /// The display path for the settings UI.
    static var displayPath: String {
        UserDefaults.standard.string(forKey: pathKey) ?? "~/Downloads"
    }
}
