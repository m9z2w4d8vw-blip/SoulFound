import Foundation
import SwiftUI

/// App-wide settings, persisted in UserDefaults. Shared as an @EnvironmentObject
/// so SettingsView can edit it and anything else (ContentView's color scheme,
/// TransferManager's write destination) can read it live.
@MainActor
final class AppSettings: ObservableObject {
    private enum Keys {
        static let lightMode = "soulfound.lightMode"
        static let downloadFolderBookmark = "soulfound.downloadFolderBookmark"
        static let downloadFolderDisplayName = "soulfound.downloadFolderDisplayName"
    }

    @Published var isLightMode: Bool {
        didSet { UserDefaults.standard.set(isLightMode, forKey: Keys.lightMode) }
    }

    /// Security-scoped bookmark for a user-chosen folder outside the app's
    /// own sandbox (e.g. picked via the Files app). Nil means "use the app's
    /// own Documents directory", which needs no bookmark/permission dance.
    @Published private(set) var downloadFolderBookmark: Data? {
        didSet { UserDefaults.standard.set(downloadFolderBookmark, forKey: Keys.downloadFolderBookmark) }
    }

    @Published private(set) var downloadFolderDisplayName: String {
        didSet { UserDefaults.standard.set(downloadFolderDisplayName, forKey: Keys.downloadFolderDisplayName) }
    }

    init() {
        isLightMode = UserDefaults.standard.bool(forKey: Keys.lightMode)
        downloadFolderBookmark = UserDefaults.standard.data(forKey: Keys.downloadFolderBookmark)
        downloadFolderDisplayName = UserDefaults.standard.string(forKey: Keys.downloadFolderDisplayName)
            ?? "SoulFound (app storage)"
    }

    /// Records a folder the user picked via the system folder picker.
    func setDownloadFolder(_ url: URL) {
        guard let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else {
            DebugLog.shared.log("AppSettings: failed to create bookmark for \(url)")
            return
        }
        downloadFolderBookmark = bookmark
        downloadFolderDisplayName = url.lastPathComponent
    }

    /// Reverts to the app's own sandboxed Documents directory.
    func resetDownloadFolder() {
        downloadFolderBookmark = nil
        downloadFolderDisplayName = "SoulFound (app storage)"
    }

    /// Resolves the configured download destination. `isSecurityScoped` tells
    /// the caller whether it must bracket file writes with
    /// start/stopAccessingSecurityScopedResource() — only true for a
    /// user-picked external folder, never for the app's own sandbox.
    func resolveDownloadFolder() -> (url: URL, isSecurityScoped: Bool) {
        let defaultFolder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let bookmark = downloadFolderBookmark else {
            return (defaultFolder, false)
        }

        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale) else {
            DebugLog.shared.log("AppSettings: bookmark failed to resolve, falling back to app storage")
            return (defaultFolder, false)
        }
        if isStale {
            DebugLog.shared.log("AppSettings: bookmark is stale for \(url) — still attempting to use it")
        }
        return (url, true)
    }
}
