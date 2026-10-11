import Testing
@testable import ExplorerCore

@Suite struct MountedVolumeTests {
    @Test func includesTheBootVolume() {
        let volumes = VolumeLister.mountedVolumes()
        #expect(volumes.contains { $0.url.path == "/" })
    }

    @Test func namesAreNonEmpty() {
        let volumes = VolumeLister.mountedVolumes()
        #expect(volumes.allSatisfy { !$0.name.isEmpty })
    }
}
