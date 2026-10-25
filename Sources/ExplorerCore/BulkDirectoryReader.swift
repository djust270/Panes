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

    // The C constants are imported with mixed Int32/UInt32 types; normalise them once.
    private static let cmnReturnedAttrs = attrgroup_t(truncatingIfNeeded: ATTR_CMN_RETURNED_ATTRS)
    private static let cmnName = attrgroup_t(truncatingIfNeeded: ATTR_CMN_NAME)
    private static let cmnError = attrgroup_t(truncatingIfNeeded: ATTR_CMN_ERROR)
    private static let cmnObjType = attrgroup_t(truncatingIfNeeded: ATTR_CMN_OBJTYPE)
    private static let cmnCrTime = attrgroup_t(truncatingIfNeeded: ATTR_CMN_CRTIME)
    private static let cmnModTime = attrgroup_t(truncatingIfNeeded: ATTR_CMN_MODTIME)
    private static let cmnFlags = attrgroup_t(truncatingIfNeeded: ATTR_CMN_FLAGS)
    private static let fileDataLength = attrgroup_t(truncatingIfNeeded: ATTR_FILE_DATALENGTH)

    static func read(_ directory: URL, includeHidden: Bool) throws -> [FileItem] {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw posixError(errno, directory) }
        defer { close(fd) }

        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = cmnReturnedAttrs | cmnName | cmnError | cmnObjType | cmnCrTime | cmnModTime | cmnFlags
        request.fileattr = fileDataLength

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
                guard let raw = decodeEntry(entry) else { continue }
                if let item = makeItem(raw, in: directory, includeHidden: includeHidden, types: &types) {
                    items.append(item)
                }
            }
        }
        return items
    }

    /// Decodes one entry. Layout: length, returned attribute set, then the requested
    /// attributes in bit order (ATTR_CMN_ERROR first), each present only if returned.
    private static func decodeEntry(_ start: UnsafeRawPointer) -> RawEntry? {
        var cursor = AttributeCursor(start + MemoryLayout<UInt32>.size)
        let returned = cursor.next(attribute_set_t.self)
        let common = returned.commonattr

        if common & cmnError != 0, cursor.next(UInt32.self) != 0 { return nil }
        guard common & cmnName != 0 else { return nil }

        let nameStart = cursor.pointer
        let nameRef = cursor.next(attrreference_t.self)
        var raw = RawEntry(
            name: String(cString: (nameStart + Int(nameRef.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
        )

        if common & cmnObjType != 0 { raw.objectType = cursor.next(fsobj_type_t.self) }
        if common & cmnCrTime != 0 { raw.created = date(cursor.next(timespec.self)) }
        if common & cmnModTime != 0 { raw.modified = date(cursor.next(timespec.self)) }
        if common & cmnFlags != 0 { raw.flags = cursor.next(UInt32.self) }
        if returned.fileattr & fileDataLength != 0 { raw.size = cursor.next(off_t.self) }
        return raw
    }

    private static func makeItem(
        _ raw: RawEntry,
        in directory: URL,
        includeHidden: Bool,
        types: inout TypeCache
    ) -> FileItem? {
        let isHidden = raw.name.hasPrefix(".") || raw.flags & UInt32(UF_HIDDEN) != 0
        if isHidden && !includeHidden { return nil }

        let ext = (raw.name as NSString).pathExtension.lowercased()
        let kind: FileItem.Kind
        let typeIdentifier: String?
        switch raw.objectType {
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

        var item = FileItem(
            url: directory.appendingPathComponent(raw.name, isDirectory: kind == .directory || kind == .package),
            name: raw.name,
            kind: kind,
            size: kind == .directory ? nil : raw.size,
            dateModified: raw.modified,
            dateCreated: raw.created,
            isHidden: isHidden,
            typeIdentifier: typeIdentifier
        )
        item.isOnlineOnly = raw.flags & UInt32(SF_DATALESS) != 0
        return item
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
}

/// Attributes decoded from one `getattrlistbulk` entry, before classification.
private struct RawEntry {
    var name: String
    var objectType = fsobj_type_t(VREG.rawValue)
    var created: Date?
    var modified: Date?
    var flags: UInt32 = 0
    var size: Int64?
}

/// Reads consecutive, possibly unaligned values from an attribute buffer.
private struct AttributeCursor {
    private(set) var pointer: UnsafeRawPointer

    init(_ pointer: UnsafeRawPointer) {
        self.pointer = pointer
    }

    mutating func next<T: BitwiseCopyable>(_: T.Type) -> T {
        let value = pointer.loadUnaligned(as: T.self)
        pointer += MemoryLayout<T>.size
        return value
    }
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
