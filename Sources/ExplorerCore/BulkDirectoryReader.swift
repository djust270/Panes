import Darwin
import Foundation
import UniformTypeIdentifiers

/// Fast directory listing via `getattrlistbulk(2)`, which returns attributes for many
/// entries per system call. Several times faster than `FileManager` on large folders.
///
/// Limitation: package detection is by extension only (e.g. `.app`, `.bundle`); legacy
/// directories marked as bundles via Finder flags are reported as plain directories.
enum BulkDirectoryReader {
    struct Unsupported: Error {}

    private static let bufferSize = 256 * 1024

    static func read(_ directory: URL, includeHidden: Bool) throws -> [FileItem] {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw posixError(errno, directory) }
        defer { close(fd) }

        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        // The C constants are imported with mixed Int32/UInt32 types; normalise them.
        let returnedAttrs = attrgroup_t(truncatingIfNeeded: ATTR_CMN_RETURNED_ATTRS)
        let name = attrgroup_t(truncatingIfNeeded: ATTR_CMN_NAME)
        let error = attrgroup_t(truncatingIfNeeded: ATTR_CMN_ERROR)
        let objType = attrgroup_t(truncatingIfNeeded: ATTR_CMN_OBJTYPE)
        let crTime = attrgroup_t(truncatingIfNeeded: ATTR_CMN_CRTIME)
        let modTime = attrgroup_t(truncatingIfNeeded: ATTR_CMN_MODTIME)
        let flags = attrgroup_t(truncatingIfNeeded: ATTR_CMN_FLAGS)
        request.commonattr = returnedAttrs | name | error | objType | crTime | modTime | flags
        request.fileattr = attrgroup_t(ATTR_FILE_DATALENGTH)

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }

        var types = TypeCache()
        var items: [FileItem] = []

        while true {
            try Task.checkCancellation()
            let count = getattrlistbulk(fd, &request, buffer, bufferSize, 0)
            if count == 0 { break }
            if count < 0 {
                if errno == ENOTSUP || errno == EINVAL { throw Unsupported() }
                throw posixError(errno, directory)
            }

            var entry = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                defer { entry += length }
                if let item = parseEntry(entry, in: directory, includeHidden: includeHidden, types: &types) {
                    items.append(item)
                }
            }
        }
        return items
    }

    /// Layout per entry: length, returned attribute set, then requested attributes in
    /// bit order (ATTR_CMN_ERROR first), each present only if flagged as returned.
    private static func parseEntry(
        _ start: UnsafeRawPointer,
        in directory: URL,
        includeHidden: Bool,
        types: inout TypeCache
    ) -> FileItem? {
        var cursor = start + MemoryLayout<UInt32>.size
        let returned = cursor.loadUnaligned(as: attribute_set_t.self)
        cursor += MemoryLayout<attribute_set_t>.size
        let common = returned.commonattr

        if common & attrgroup_t(ATTR_CMN_ERROR) != 0 {
            let error = cursor.loadUnaligned(as: UInt32.self)
            cursor += MemoryLayout<UInt32>.size
            if error != 0 { return nil }
        }

        guard common & attrgroup_t(ATTR_CMN_NAME) != 0 else { return nil }
        let nameRef = cursor.loadUnaligned(as: attrreference_t.self)
        let namePointer = (cursor + Int(nameRef.attr_dataoffset)).assumingMemoryBound(to: CChar.self)
        let name = String(cString: namePointer)
        cursor += MemoryLayout<attrreference_t>.size

        var objectType = fsobj_type_t(VREG.rawValue)
        if common & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
            objectType = cursor.loadUnaligned(as: fsobj_type_t.self)
            cursor += MemoryLayout<fsobj_type_t>.size
        }

        var created: Date?
        if common & attrgroup_t(ATTR_CMN_CRTIME) != 0 {
            created = date(cursor.loadUnaligned(as: timespec.self))
            cursor += MemoryLayout<timespec>.size
        }

        var modified: Date?
        if common & attrgroup_t(ATTR_CMN_MODTIME) != 0 {
            modified = date(cursor.loadUnaligned(as: timespec.self))
            cursor += MemoryLayout<timespec>.size
        }

        var flags: UInt32 = 0
        if common & attrgroup_t(ATTR_CMN_FLAGS) != 0 {
            flags = cursor.loadUnaligned(as: UInt32.self)
            cursor += MemoryLayout<UInt32>.size
        }

        var size: Int64?
        if returned.fileattr & attrgroup_t(ATTR_FILE_DATALENGTH) != 0 {
            size = cursor.loadUnaligned(as: off_t.self)
        }

        let isHidden = name.hasPrefix(".") || flags & UInt32(UF_HIDDEN) != 0
        if isHidden && !includeHidden { return nil }

        let ext = (name as NSString).pathExtension.lowercased()
        let kind: FileItem.Kind
        let typeIdentifier: String?
        switch objectType {
        case fsobj_type_t(VDIR.rawValue):
            if let type = types.type(forExtension: ext, directory: true), type.conforms(to: .package) {
                kind = .package
                typeIdentifier = type.identifier
            } else {
                kind = .directory
                typeIdentifier = UTType.folder.identifier
            }
        case fsobj_type_t(VLNK.rawValue):
            kind = .symlink
            typeIdentifier = UTType.symbolicLink.identifier
        default:
            kind = .file
            typeIdentifier = types.type(forExtension: ext, directory: false)?.identifier ?? UTType.data.identifier
        }

        return FileItem(
            url: directory.appendingPathComponent(name, isDirectory: kind == .directory || kind == .package),
            name: name,
            kind: kind,
            size: kind == .directory ? nil : size,
            dateModified: modified,
            dateCreated: created,
            isHidden: isHidden,
            typeIdentifier: typeIdentifier
        )
    }

    private static func date(_ time: timespec) -> Date {
        Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000)
    }

    private static func posixError(_ code: Int32, _ url: URL) -> Error {
        let posix = POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        let cocoaCode: CocoaError.Code = switch code {
        case ENOENT, ENOTDIR: .fileReadNoSuchFile
        case EACCES, EPERM: .fileReadNoPermission
        default: .fileReadUnknown
        }
        return CocoaError(cocoaCode, userInfo: [NSURLErrorKey: url, NSUnderlyingErrorKey: posix])
    }

    /// Memoises extension → UTType lookups; folders usually repeat a handful of extensions.
    private struct TypeCache {
        private struct Key: Hashable {
            let ext: String
            let directory: Bool
        }

        private var cache: [Key: UTType?] = [:]

        /// Directory extensions (e.g. `app`) are only found when searching under `.directory`.
        mutating func type(forExtension ext: String, directory: Bool) -> UTType? {
            guard !ext.isEmpty else { return nil }
            let key = Key(ext: ext, directory: directory)
            if let cached = cache[key] { return cached }
            let type = UTType(filenameExtension: ext, conformingTo: directory ? .directory : .data)
            cache[key] = type
            return type
        }
    }
}
