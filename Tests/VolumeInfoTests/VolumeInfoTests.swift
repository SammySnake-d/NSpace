import Testing
import Foundation
import VolumeInfo

/// 黑盒验收：真实系统卷（无 Fake Mock）
@Suite struct VolumeInfoTests {
    @Test func volumesContainRootWithCapacity() {
        let vols = VolumeInfo().volumes()
        #expect(!vols.isEmpty)
        let root = vols.first { $0.isRoot }
        #expect(root != nil)
        #expect((root?.totalCapacity ?? 0) > 0)
        #expect((root?.availableCapacity ?? 0) > 0)
        #expect(root?.isEjectable != true)
    }

    @Test func ejectRootFailsClassified() {
        // 根卷不可推出：必须抛分类错误而不是崩溃
        do {
            try VolumeInfo().eject(URL(fileURLWithPath: "/"))
            Issue.record("推出根卷应当失败")
        } catch let e as VolumeError {
            #expect(e.errorClass == .external)
        } catch {
            Issue.record("错误未分类: \(error)")
        }
    }
}
