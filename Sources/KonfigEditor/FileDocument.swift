import Foundation
import Darwin

/// A disk baseline is tied to both the resolved destination and its loaded contents.
struct FileDocument: Equatable {
    let target: URL
    let data: Data?
    let modificationDate: Date?
    let fileNumber: UInt64?
    let permissions: UInt16?

    enum AccessError: LocalizedError {
        case conflict, unreadable, danglingLink
        var errorDescription: String? {
            switch self {
            case .conflict: return L10n.text("The file changed outside DotShelf. Reload it before saving; copy your edits first if you want to keep them.")
            case .unreadable: return L10n.text("The file could not be loaded safely. Reload it before saving.")
            case .danglingLink: return L10n.text("The symbolic link has no readable target. Restore its target before saving.")
            }
        }
    }

    static func entryExists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    static func read(_ url: URL) throws -> FileDocument {
        let fm = FileManager.default
        let target = url.resolvingSymlinksInPath().standardizedFileURL
        if !fm.fileExists(atPath: target.path) {
            if entryExists(url) || entryExists(target) { throw AccessError.danglingLink }
            return FileDocument(target: target, data: nil, modificationDate: nil, fileNumber: nil, permissions: nil)
        }
        let attrs = try fm.attributesOfItem(atPath: target.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular else { throw AccessError.unreadable }
        let data = try Data(contentsOf: target)
        return FileDocument(target: target, data: data,
            modificationDate: attrs[.modificationDate] as? Date,
            fileNumber: (attrs[.systemFileNumber] as? NSNumber)?.uint64Value,
            permissions: (attrs[.posixPermissions] as? NSNumber)?.uint16Value)
    }

    /// Moving the entry changes its location, not the baseline contents.
    func relocated(to url: URL) -> FileDocument {
        FileDocument(target: url.resolvingSymlinksInPath().standardizedFileURL,
                     data: data, modificationDate: modificationDate,
                     fileNumber: fileNumber, permissions: permissions)
    }

    func checkUnchanged(at url: URL) throws {
        guard try Self.read(url) == self else { throw AccessError.conflict }
    }

    /// Stage on the destination filesystem, retain metadata, then atomically replace the target.
    func write(_ content: String, at url: URL, backup: Bool) throws -> FileDocument {
        let fm = FileManager.default
        try checkUnchanged(at: url)
        let dir = target.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let stage = dir.appendingPathComponent(".dotshelf-\(UUID().uuidString).tmp")
        defer { try? fm.removeItem(at: stage) }
        if data != nil {
            try fm.copyItem(at: target, to: stage)
            guard try Data(contentsOf: stage) == data else { throw AccessError.conflict }
        } else {
            guard fm.createFile(atPath: stage.path, contents: Data(), attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        if backup, data != nil {
            try Self.storeBackup(of: stage, for: target, using: fm)
        }
        let handle = try FileHandle(forWritingTo: stage)
        do {
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data(content.utf8))
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        try checkUnchanged(at: url)
        let result: Int32
        if data == nil {
            result = renamex_np(stage.path, target.path, UInt32(RENAME_EXCL))
        } else {
            result = Darwin.rename(stage.path, target.path)
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return try Self.read(url)
    }

    // MARK: - Backups

    /// Snapshots collect in one hidden folder per directory instead of one loose
    /// file per save, so editing a dotfile repeatedly leaves the directory clean.
    static let backupFolderName = ".dotshelf"

    /// One subfolder per protected file keeps a long history readable.
    static func backupFolder(for target: URL) -> URL {
        target.deletingLastPathComponent()
            .appendingPathComponent(backupFolderName, isDirectory: true)
            .appendingPathComponent(target.lastPathComponent, isDirectory: true)
    }

    /// Snapshot name: UTC stamp without colons, plus a counter when two saves
    /// land in the same second.
    static func backupURL(for target: URL, at date: Date = Date(), using fm: FileManager = .default) -> URL {
        let stamp = ISO8601DateFormatter().string(from: date).replacingOccurrences(of: ":", with: "-")
        let folder = backupFolder(for: target)
        var candidate = folder.appendingPathComponent("\(stamp).bak")
        var attempt = 1
        while entryExists(candidate) {
            candidate = folder.appendingPathComponent("\(stamp)-\(attempt).bak")
            attempt += 1
        }
        return candidate
    }

    private static func storeBackup(of stage: URL, for target: URL, using fm: FileManager) throws {
        let folder = backupFolder(for: target)
        let root = folder.deletingLastPathComponent()
        try fm.createDirectory(at: root, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try keepSnapshotsUntracked(in: root, using: fm)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.copyItem(at: stage, to: backupURL(for: target, using: fm))
    }

    /// Dotfile repositories would otherwise report every snapshot as untracked.
    private static func keepSnapshotsUntracked(in root: URL, using fm: FileManager) throws {
        let ignore = root.appendingPathComponent(".gitignore")
        guard !entryExists(ignore) else { return }
        try Data("*\n".utf8).write(to: ignore)
    }
}
