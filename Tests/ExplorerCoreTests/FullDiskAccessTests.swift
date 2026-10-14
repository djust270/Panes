import Foundation
import Testing
@testable import ExplorerCore

@Suite struct FullDiskAccessTests {
    @Test func probesTellGrantedFromDenied() throws {
        let home = try TemporaryDirectory()
        #expect(FullDiskAccess.status(home: home.url) == .unknown)

        let probe = home.url.appendingPathComponent(FullDiskAccess.probes[0])
        try FileManager.default.createDirectory(at: probe.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data().write(to: probe)
        #expect(FullDiskAccess.status(home: home.url) == .granted)

        chmod(probe.path, 0)
        defer { chmod(probe.path, 0o644) }
        #expect(FullDiskAccess.status(home: home.url) == .denied)
    }

    @Test func privacyDenialsAreEPERMOnly() {
        let eperm = CocoaError(.fileReadNoPermission, userInfo: [NSUnderlyingErrorKey: POSIXError(.EPERM)])
        let eacces = CocoaError(.fileReadNoPermission, userInfo: [NSUnderlyingErrorKey: POSIXError(.EACCES)])
        #expect(FullDiskAccess.isPrivacyDenial(eperm))
        #expect(!FullDiskAccess.isPrivacyDenial(eacces))
        #expect(FullDiskAccess.isPermissionDenial(eacces))
        #expect(!FullDiskAccess.isPermissionDenial(CocoaError(.fileReadNoSuchFile)))
    }
}
