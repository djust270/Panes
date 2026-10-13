import Darwin
import Foundation

/// The permissions Windows' Security tab lists, in its order.
public enum WindowsPermission: String, Sendable, Hashable, CaseIterable {
    case fullControl, modify, readAndExecute, listFolderContents, read, write
    /// Rights that don't add up to any of the others (e.g. "deny delete").
    case special

    public var title: String {
        switch self {
        case .fullControl: return "Full control"
        case .modify: return "Modify"
        case .readAndExecute: return "Read & execute"
        case .listFolderContents: return "List folder contents"
        case .read: return "Read"
        case .write: return "Write"
        case .special: return "Special permissions"
        }
    }

    /// The rows shown for a file or a folder (List folder contents is for folders only).
    public static func rows(forDirectory isDirectory: Bool) -> [WindowsPermission] {
        allCases.filter { isDirectory || $0 != .listFolderContents }
    }
}

/// Owner, group or everyone's POSIX bits: read, write, execute (search, for folders).
public struct PosixAccess: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let read = PosixAccess(rawValue: 4)
    public static let write = PosixAccess(rawValue: 2)
    public static let execute = PosixAccess(rawValue: 1)
    public static let all: PosixAccess = [.read, .write, .execute]
}

/// One row of the Security tab's "Group or user names" list, with its Allow and Deny columns.
public struct PermissionEntry: Sendable, Hashable {
    public enum Source: Sendable, Hashable {
        /// The owner's, group's or everyone else's POSIX bits; editable by the owner.
        case owner, group, everyone
        /// An access control entry, shown but not edited here.
        case accessControl
    }

    /// "dave (Owner)", "staff (Group)", "Everyone".
    public var name: String
    public var source: Source
    public var allowed: Set<WindowsPermission>
    public var denied: Set<WindowsPermission>

    public init(name: String, source: Source, allowed: Set<WindowsPermission>, denied: Set<WindowsPermission> = []) {
        self.name = name
        self.source = source
        self.allowed = allowed
        self.denied = denied
    }

    public var isPosix: Bool { source != .accessControl }
}

/// Maps POSIX bits and access control lists to Windows' permission names, and back.
///
/// POSIX: Read = r; Write = w; Read & execute and List folder contents = r+x; Modify = r+w
/// (+x for folders); Full control = Modify for the owner, who alone can change permissions.
public enum WindowsPermissions {
    public static func permissions(
        for access: PosixAccess,
        isDirectory: Bool,
        isOwner: Bool
    ) -> Set<WindowsPermission> {
        var result: Set<WindowsPermission> = []
        if access.contains(.read) { result.insert(.read) }
        if access.contains(.write) { result.insert(.write) }
        if access.contains([.read, .execute]) {
            result.insert(.readAndExecute)
            if isDirectory { result.insert(.listFolderContents) }
        }
        if access.isSuperset(of: modifyAccess(isDirectory: isDirectory)) {
            result.insert(.modify)
            if isOwner { result.insert(.fullControl) }
        }
        return result
    }

    /// The bits after checking (`allowed`) or unchecking `permission`, cascading the way
    /// Windows' checkboxes do: checking Modify also checks Read and Write; unchecking Read
    /// unchecks everything that includes it.
    public static func access(
        _ access: PosixAccess,
        setting permission: WindowsPermission,
        to allowed: Bool,
        isDirectory: Bool
    ) -> PosixAccess {
        var result = access
        switch (permission, allowed) {
        case (.read, true): result.insert(.read)
        case (.read, false): result.remove(.read)
        case (.write, true): result.insert(.write)
        case (.write, false): result.remove(.write)
        case (.readAndExecute, true), (.listFolderContents, true): result.formUnion([.read, .execute])
        case (.readAndExecute, false), (.listFolderContents, false): result.remove(.execute)
        case (.modify, true), (.fullControl, true): result.formUnion(modifyAccess(isDirectory: isDirectory))
        case (.modify, false), (.fullControl, false): result.remove(.write)
        case (.special, _): break
        }
        return result
    }

    private static func modifyAccess(isDirectory: Bool) -> PosixAccess {
        isDirectory ? .all : [.read, .write]
    }

    /// The owner, group and everyone rows for POSIX `mode` bits.
    public static func posixEntries(mode: Int, owner: String, group: String, isDirectory: Bool) -> [PermissionEntry] {
        func access(_ shift: Int) -> PosixAccess { PosixAccess(rawValue: (mode >> shift) & 7) }
        return [
            PermissionEntry(name: "\(owner) (Owner)", source: .owner,
                            allowed: permissions(for: access(6), isDirectory: isDirectory, isOwner: true)),
            PermissionEntry(name: "\(group) (Group)", source: .group,
                            allowed: permissions(for: access(3), isDirectory: isDirectory, isOwner: false)),
            PermissionEntry(name: "Everyone", source: .everyone,
                            allowed: permissions(for: access(0), isDirectory: isDirectory, isOwner: false)),
        ]
    }

    /// The POSIX rows followed by the access control entries, with an "everyone" entry merged
    /// into the Everyone row: Windows lists each name once.
    public static func combined(posix: [PermissionEntry], accessControl: [PermissionEntry]) -> [PermissionEntry] {
        var rows = posix
        var extra: [PermissionEntry] = []
        for entry in accessControl {
            if entry.name == "Everyone", let index = rows.firstIndex(where: { $0.source == .everyone }) {
                rows[index].allowed.formUnion(entry.allowed)
                rows[index].denied.formUnion(entry.denied)
            } else {
                extra.append(entry)
            }
        }
        return rows + extra
    }

    /// `mode` with the bits of the owner, group or everyone (`source`) replaced by `access`.
    public static func mode(_ mode: Int, setting access: PosixAccess, for source: PermissionEntry.Source) -> Int {
        let shift: Int
        switch source {
        case .owner: shift = 6
        case .group: shift = 3
        case .everyone: shift = 0
        case .accessControl: return mode
        }
        return (mode & ~(7 << shift)) | (access.rawValue << shift)
    }

    // MARK: Access control lists

    /// Rows for the access control entries in `text` (from `acl_to_text`), one per user or
    /// group and Allow/Deny, merged as Windows shows them.
    public static func accessControlEntries(fromText text: String, isDirectory: Bool) -> [PermissionEntry] {
        var order: [String] = []
        var rights: [String: (allow: Set<Right>, deny: Set<Right>)] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("!#acl") {
            let fields = line.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 6 else { continue }
            let name = fields[2].isEmpty ? fields[1] : fields[2]
            let display = name == "everyone" ? "Everyone" : name
            let granted = Set(fields[5].split(separator: ",").compactMap { Right(aclName: String($0)) })
            if rights[display] == nil {
                order.append(display)
                rights[display] = ([], [])
            }
            if fields[4] == "deny" {
                rights[display]?.deny.formUnion(granted)
            } else {
                rights[display]?.allow.formUnion(granted)
            }
        }
        return order.compactMap { name in
            guard let entry = rights[name] else { return nil }
            return PermissionEntry(
                name: name,
                source: .accessControl,
                allowed: permissions(for: entry.allow, isDirectory: isDirectory),
                denied: permissions(for: entry.deny, isDirectory: isDirectory)
            )
        }
    }

    /// Reads the access control entries on `url` (not following a symbolic link).
    public static func accessControlEntries(of url: URL, isDirectory: Bool) -> [PermissionEntry] {
        guard let acl = acl_get_link_np(url.path, ACL_TYPE_EXTENDED) else { return [] }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var length = 0
        guard let text = acl_to_text(acl, &length) else { return [] }
        defer { acl_free(UnsafeMutableRawPointer(text)) }
        return accessControlEntries(fromText: String(cString: text), isDirectory: isDirectory)
    }

    /// Rights in an access control entry, grouped the way Windows' permissions use them.
    enum Right: Hashable {
        case read, write, execute, delete, security, attributes

        init?(aclName: String) {
            switch aclName {
            case "read", "list": self = .read
            case "write", "append", "add_file", "add_subdirectory": self = .write
            case "execute", "search": self = .execute
            case "delete", "delete_child": self = .delete
            case "writesecurity", "chown": self = .security
            case "readattr", "writeattr", "readextattr", "writeextattr", "readsecurity": self = .attributes
            default: return nil // inheritance flags
            }
        }
    }

    /// The Windows permissions made up entirely of `rights`; rights left over make "Special".
    static func permissions(for rights: Set<Right>, isDirectory: Bool) -> Set<WindowsPermission> {
        var result: Set<WindowsPermission> = []
        let needs: [(WindowsPermission, Set<Right>)] = [
            (.read, [.read]),
            (.write, [.write]),
            (.readAndExecute, [.read, .execute]),
            (.listFolderContents, [.read, .execute]),
            (.modify, isDirectory ? [.read, .write, .execute, .delete] : [.read, .write, .delete]),
            (.fullControl, isDirectory ? [.read, .write, .execute, .delete, .security]
                : [.read, .write, .delete, .security]),
        ]
        var explained: Set<Right> = []
        for (permission, needed) in needs where needed.isSubset(of: rights) {
            if permission == .listFolderContents, !isDirectory { continue }
            result.insert(permission)
            explained.formUnion(needed)
        }
        // Attribute rights come with any of the permissions; on their own they're special.
        if !result.isEmpty { explained.insert(.attributes) }
        if !rights.subtracting(explained).isEmpty { result.insert(.special) }
        return result
    }
}
