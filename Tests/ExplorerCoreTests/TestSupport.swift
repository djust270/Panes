import Foundation

/// A uniquely named temporary directory, removed when the value is deinitialised.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExplorerCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func createFile(_ name: String, contents: String = "") throws -> URL {
        let file = url.appendingPathComponent(name)
        try Data(contents.utf8).write(to: file)
        return file
    }

    @discardableResult
    func createDirectory(_ name: String) throws -> URL {
        let dir = url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

extension TemporaryDirectory {
    func path(_ relative: String) -> URL {
        url.appendingPathComponent(relative)
    }

    func exists(_ relative: String) -> Bool {
        var info = stat()
        return lstat(path(relative).path, &info) == 0
    }

    func contents(_ relative: String) throws -> String {
        try String(contentsOf: path(relative), encoding: .utf8)
    }

    /// Creates a file at a relative path, making intermediate folders.
    @discardableResult
    func createFile(at relative: String, contents: String = "") throws -> URL {
        let file = path(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
        return file
    }
}

/// A throwaway `UserDefaults` domain, removed when the value is deinitialised.
final class TemporaryDefaults {
    let name = "ExplorerCoreTests-\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: name) ?? .standard
    }

    deinit {
        defaults.removePersistentDomain(forName: name)
    }
}
