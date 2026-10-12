import Foundation

public enum PersonalDataSyncStoreError: Error, Equatable, Sendable, LocalizedError {
    case folderUnavailable
    case invalidPackage

    public var errorDescription: String? {
        switch self {
        case .folderUnavailable:
            return "同步文件夹当前不可访问"
        case .invalidPackage:
            return "同步文件夹中的个人数据包无效"
        }
    }
}

/// The filesystem boundary for the private sync folder. It stores only the
/// versioned personal-data JSON and a durable reference to the chosen folder.
public enum PersonalDataSyncStore {
    public static let packageFileName = "LyricIslandPersonalData.json"

    private static let folderBookmarkDefaultsKey = "personalDataSync.folderBookmark.v1"
    private static let folderPathDefaultsKey = "personalDataSync.folderPath.v1"

    public static func packageURL(in folder: URL) -> URL {
        folder.appendingPathComponent(packageFileName, isDirectory: false)
    }

    public static func saveFolderReference(
        _ folder: URL,
        defaults: UserDefaults = .lyricsQ
    ) throws {
        let normalizedFolder = folder.standardizedFileURL
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: normalizedFolder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw PersonalDataSyncStoreError.folderUnavailable
        }

        // The current app is not sandboxed, so the path remains a valid
        // restart-safe fallback even if bookmark creation is unavailable.
        defaults.set(normalizedFolder.path, forKey: folderPathDefaultsKey)
        do {
            let bookmark = try normalizedFolder.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            defaults.set(bookmark, forKey: folderBookmarkDefaultsKey)
        } catch {
            defaults.removeObject(forKey: folderBookmarkDefaultsKey)
        }
    }

    public static func restoreFolderReference(
        defaults: UserDefaults = .lyricsQ
    ) -> URL? {
        if let bookmark = defaults.data(forKey: folderBookmarkDefaultsKey) {
            var isStale = false
            if let resolved = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope, .withoutUI, .withoutMounting],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                if isStale {
                    try? saveFolderReference(resolved, defaults: defaults)
                }
                return resolved.standardizedFileURL
            }
        }

        guard let path = defaults.string(forKey: folderPathDefaultsKey), !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    public static func clearFolderReference(defaults: UserDefaults = .lyricsQ) {
        defaults.removeObject(forKey: folderBookmarkDefaultsKey)
        defaults.removeObject(forKey: folderPathDefaultsKey)
    }

    public static func encode(_ package: PersonalDataPackage) throws -> Data {
        try package.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(package)
    }

    public static func decode(_ data: Data) throws -> PersonalDataPackage {
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let package = try decoder.decode(PersonalDataPackage.self, from: data)
            try package.validate()
            return package
        } catch let error as PersonalDataPackageError {
            throw error
        } catch {
            throw PersonalDataSyncStoreError.invalidPackage
        }
    }

    public static func read(from folder: URL) throws -> PersonalDataPackage? {
        let url = packageURL(in: folder)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decode(Data(contentsOf: url))
    }

    public static func write(_ package: PersonalDataPackage, to folder: URL) throws {
        let data = try encode(package)
        let normalizedFolder = folder.standardizedFileURL
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: normalizedFolder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw PersonalDataSyncStoreError.folderUnavailable
        }

        let destination = packageURL(in: normalizedFolder)
        let temporary = normalizedFolder.appendingPathComponent(
            ".\(packageFileName).\(UUID().uuidString).tmp",
            isDirectory: false
        )

        do {
            try data.write(to: temporary, options: [.atomic])
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    public static func withFolderAccess<T>(
        _ folder: URL,
        operation: () throws -> T
    ) rethrows -> T {
        let didStartAccess = folder.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                folder.stopAccessingSecurityScopedResource()
            }
        }
        return try operation()
    }
}
