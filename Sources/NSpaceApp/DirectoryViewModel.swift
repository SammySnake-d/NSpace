import Foundation
import NSpaceContracts
import DirectoryReader

/// 每窗格内容的胶水：订阅 DirectoryReader 投影，持有快照，代际防过期覆盖（spec 3.2）。
/// 展示层只读消费——本类不含任何写型文件操作（BG-1）。
@MainActor
final class DirectoryViewModel {
    private let reader = DirectoryReader()

    private(set) var directory: URL
    private(set) var items: [FileItem] = []
    private(set) var isLoading = false

    var includeHidden = false { didSet { reload() } }
    var sort = SortSpec() { didSet { reload() } }

    var onUpdate: (() -> Void)?
    /// 就地错误呈现（原位空态横幅，严禁弹窗轰炸——spec 容错矩阵）
    var onError: ((String) -> Void)?

    private var lastAppliedGeneration: UInt64 = 0
    private var loadTask: Task<Void, Never>?

    init(directory: URL) {
        self.directory = directory
    }

    func navigate(to url: URL) {
        directory = url
        lastAppliedGeneration = 0  // 新目录重置代际基线
        reload()
    }

    func reload() {
        loadTask?.cancel()
        isLoading = true
        let request = ReadRequest(directory: directory, includeHidden: includeHidden, sort: sort)
        loadTask = Task { [weak self, reader] in
            do {
                let snap = try await reader.load(request)
                guard let self, !Task.isCancelled else { return }
                guard snap.generation > self.lastAppliedGeneration,
                      snap.directory == self.directory else { return }
                self.lastAppliedGeneration = snap.generation
                self.items = snap.items
                self.isLoading = false
                self.onUpdate?()
            } catch is CancellationError {
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.isLoading = false
                self.items = []
                self.onUpdate?()
                self.onError?(error.localizedDescription)
            }
        }
    }
}
